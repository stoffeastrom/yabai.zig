const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = @import("../platform/c.zig");
const runloop = @import("../platform/runloop.zig");
const Response = @import("Response.zig");

const log = std.log.scoped(.ipc);

/// Unix domain socket server for yabai.zig IPC
pub const Server = @This();

const SOCKET_PATH_FMT = "/tmp/yabai.zig_{s}.socket";
const MAX_PATH_LEN = 256;
const MAX_MESSAGE_LEN = 4096;
const LISTEN_BACKLOG = 128;

/// Message handler callback type
pub const MessageHandler = *const fn (client_fd: posix.socket_t, message: []const u8, context: ?*anyopaque) void;

pub const InitError = error{
    NoUser,
    SocketCreationFailed,
    BindFailed,
    ListenFailed,
    PathTooLong,
    CFSocketFailed,
    RunLoopSourceFailed,
} || posix.UnexpectedError;

allocator: std.mem.Allocator,
socket_path: [MAX_PATH_LEN]u8,
socket_path_len: usize,
socket_fd: posix.socket_t,
handler: MessageHandler,
handler_context: ?*anyopaque,

// CFRunLoop integration
cf_socket: c.c.CFSocketRef = null,
cf_source: c.c.CFRunLoopSourceRef = null,

pub fn init(allocator: std.mem.Allocator, handler: MessageHandler, context: ?*anyopaque) InitError!Server {
    // Get username for socket path
    const user = std.posix.getenv("USER") orelse return error.NoUser;

    // Format socket path
    var socket_path: [MAX_PATH_LEN]u8 = undefined;
    const path_slice = std.fmt.bufPrint(&socket_path, SOCKET_PATH_FMT, .{user}) catch {
        return error.PathTooLong;
    };
    const socket_path_len = path_slice.len;

    // Remove existing socket file if present
    std.fs.cwd().deleteFile(path_slice) catch {};

    // Create socket
    const socket_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        return error.SocketCreationFailed;
    };
    errdefer posix.close(socket_fd);

    // Bind
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path_len], path_slice);

    posix.bind(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        return error.BindFailed;
    };

    // Listen
    posix.listen(socket_fd, LISTEN_BACKLOG) catch {
        return error.ListenFailed;
    };

    log.info("listening on {s}", .{path_slice});

    return .{
        .allocator = allocator,
        .socket_path = socket_path,
        .socket_path_len = socket_path_len,
        .socket_fd = socket_fd,
        .handler = handler,
        .handler_context = context,
    };
}

pub fn deinit(self: *Server) void {
    self.removeFromRunLoop();
    // Note: CFSocketInvalidate closes the underlying fd, so we don't close it again

    // Remove socket file
    const path = self.socket_path[0..self.socket_path_len];
    std.fs.cwd().deleteFile(path) catch {};
}

/// Add socket to main CFRunLoop for event-driven accept
pub fn addToRunLoop(self: *Server) InitError!void {
    // Create CFSocket context pointing to self
    var ctx = c.c.CFSocketContext{
        .version = 0,
        .info = self,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };

    // Create CFSocket wrapping our native socket
    self.cf_socket = c.c.CFSocketCreateWithNative(
        null,
        self.socket_fd,
        c.c.kCFSocketReadCallBack, // Notify when readable (new connection)
        cfSocketCallback,
        &ctx,
    );

    if (self.cf_socket == null) {
        return error.CFSocketFailed;
    }

    // Create run loop source
    self.cf_source = c.c.CFSocketCreateRunLoopSource(null, self.cf_socket, 0);
    if (self.cf_source == null) {
        c.c.CFRelease(self.cf_socket);
        self.cf_socket = null;
        return error.RunLoopSourceFailed;
    }

    // Add to main run loop
    runloop.addSource(runloop.getMain(), self.cf_source, runloop.defaultMode());
    log.info("IPC server added to run loop", .{});
}

/// Remove socket from run loop
pub fn removeFromRunLoop(self: *Server) void {
    if (self.cf_source) |source| {
        runloop.removeSource(runloop.getMain(), source, runloop.defaultMode());
        c.c.CFRelease(source);
        self.cf_source = null;
    }
    if (self.cf_socket) |socket| {
        c.c.CFSocketInvalidate(socket);
        c.c.CFRelease(socket);
        self.cf_socket = null;
    }
}

/// CFSocket callback - called when socket has data (new connection)
fn cfSocketCallback(
    _: c.c.CFSocketRef,
    callback_type: c.c.CFSocketCallBackType,
    _: c.c.CFDataRef,
    _: ?*const anyopaque,
    info: ?*anyopaque,
) callconv(.c) void {
    if (callback_type != c.c.kCFSocketReadCallBack) return;

    const self: *Server = @ptrCast(@alignCast(info));
    self.handleNewConnection();
}

fn handleNewConnection(self: *Server) void {
    const client_fd = posix.accept(self.socket_fd, null, null, 0) catch |err| {
        log.warn("accept failed: {}", .{err});
        return;
    };

    // Read message from client
    var buf: [MAX_MESSAGE_LEN]u8 = undefined;
    const len = posix.read(client_fd, &buf) catch {
        posix.close(client_fd);
        return;
    };

    if (len == 0) {
        posix.close(client_fd);
        return;
    }

    // Call handler
    self.handler(client_fd, buf[0..len], self.handler_context);

    // Close client connection
    posix.close(client_fd);
}

/// Send a response to a client
pub fn sendResponse(client_fd: posix.socket_t, response: []const u8) void {
    _ = posix.write(client_fd, response) catch {};
}

/// Send an error response to a client
pub fn sendError(client_fd: posix.socket_t, message: []const u8) void {
    // FAILURE_MESSAGE = 0x07
    var buf: [MAX_MESSAGE_LEN]u8 = undefined;
    buf[0] = 0x07;
    const copy_len = @min(message.len, buf.len - 1);
    @memcpy(buf[1..][0..copy_len], message[0..copy_len]);
    sendResponse(client_fd, buf[0 .. copy_len + 1]);
}

/// Send a structured error response to a client
pub fn sendErr(client_fd: posix.socket_t, err: Response.Error) void {
    var buf: [MAX_MESSAGE_LEN]u8 = undefined;
    const msg = err.format(buf[1..]);
    buf[0] = 0x07; // FAILURE_MESSAGE
    sendResponse(client_fd, buf[0 .. msg.len + 1]);
}

/// Send a failure response with raw message (used for JSON errors)
pub fn sendFailure(client_fd: posix.socket_t, message: []const u8) void {
    var buf: [MAX_MESSAGE_LEN]u8 = undefined;
    buf[0] = 0x07; // FAILURE_MESSAGE
    const copy_len = @min(message.len, buf.len - 1);
    @memcpy(buf[1..][0..copy_len], message[0..copy_len]);
    sendResponse(client_fd, buf[0 .. copy_len + 1]);
}

/// Get the socket path
pub fn getSocketPath(self: *const Server) []const u8 {
    return self.socket_path[0..self.socket_path_len];
}

// ============================================================================
// Tests
// ============================================================================

test "Server path formatting" {
    // Just test the path format logic
    var path: [MAX_PATH_LEN]u8 = undefined;
    const result = std.fmt.bufPrint(&path, SOCKET_PATH_FMT, .{"testuser"});
    try std.testing.expect(result != error.NoSpaceLeft);
    if (result) |p| {
        try std.testing.expectEqualStrings("/tmp/yabai.zig_testuser.socket", p);
    } else |_| {}
}
