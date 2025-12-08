//! Daemon initialization functions
//! Handles precondition checks, path setup, lock acquisition, and macOS subsystem init.

const std = @import("std");
const c = @import("../platform/c.zig");
const ax = @import("../platform/accessibility.zig");
const skylight = @import("../platform/skylight.zig");
const SAClient = @import("../sa/client.zig").Client;

const log = std.log.scoped(.daemon);

pub const InitError = error{
    NoUser,
    RunningAsRoot,
    NoAccessibility,
    SeparateSpacesDisabled,
    LockFileCreate,
    LockFileAcquire,
    SkylightInit,
    ServerInit,
};

/// Check preconditions for daemon startup
pub fn checkPreconditions() InitError!void {
    // Check not running as root
    if (c.c.getuid() == 0) {
        log.err("running as root is not allowed", .{});
        return error.RunningAsRoot;
    }

    // Check accessibility permissions
    if (!ax.isProcessTrustedWithOptions(true)) {
        log.err("could not access accessibility features", .{});
        return error.NoAccessibility;
    }
}

/// Initialize file paths for socket, SA socket, and lock file
pub fn initPaths(
    socket_path: *[512]u8,
    sa_socket_path: *[512]u8,
    lock_path: *[512]u8,
) InitError![]const u8 {
    const user = std.posix.getenv("USER") orelse {
        log.err("'env USER' not set", .{});
        return error.NoUser;
    };

    // Format socket paths - buffers are 512 bytes, paths are ~40 chars max
    _ = std.fmt.bufPrintZ(socket_path, "/tmp/yabai.zig_{s}.socket", .{user}) catch unreachable;
    _ = std.fmt.bufPrintZ(sa_socket_path, "/tmp/yabai.zig-sa_{s}.socket", .{user}) catch unreachable;
    _ = std.fmt.bufPrintZ(lock_path, "/tmp/yabai.zig_{s}.lock", .{user}) catch unreachable;

    return std.mem.sliceTo(sa_socket_path, 0);
}

/// Acquire exclusive lock file to prevent multiple instances
pub fn acquireLock(lock_path: *const [512]u8) InitError!std.posix.fd_t {
    const path = std.mem.sliceTo(lock_path, 0);

    const fd = std.posix.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
    }, 0o600) catch {
        log.err("could not create lock file: {s}", .{path});
        return error.LockFileCreate;
    };

    // Try to acquire exclusive lock (non-blocking)
    std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch {
        std.posix.close(fd);
        log.err("could not acquire lock - another instance running?", .{});
        return error.LockFileAcquire;
    };

    return fd;
}

/// Result from macOS initialization
pub const MacOSInitResult = struct {
    skylight: *const skylight.SkyLight,
    connection: c_int,
    pid: c.pid_t,
    layer_normal: c_int,
    layer_below: c_int,
    layer_above: c_int,
};

/// Initialize macOS subsystems (SkyLight, signals, etc.)
pub fn initMacOS(signal_handler: *const fn (c_int) callconv(.c) void) InitError!MacOSInitResult {
    // Load NSApplication (required for event loop)
    _ = c.NSApplicationLoad();

    // Get our PID
    const pid = c.getpid();

    // Initialize SkyLight
    const sl = skylight.get() catch {
        log.err("failed to load SkyLight framework", .{});
        return error.SkylightInit;
    };

    // Get main connection ID
    const connection = sl.SLSMainConnectionID();

    // Check "displays have separate spaces" is enabled
    if (sl.SLSGetSpaceManagementMode(connection) != 1) {
        log.err("'display has separate spaces' is disabled", .{});
        return error.SeparateSpacesDisabled;
    }

    // Get window level constants
    const layer_normal = c.c.CGWindowLevelForKey(c.c.kCGNormalWindowLevelKey);
    const layer_below = c.c.CGWindowLevelForKey(c.c.kCGDesktopIconWindowLevelKey);
    const layer_above = c.c.CGWindowLevelForKey(c.c.kCGFloatingWindowLevelKey);

    // Ignore SIGCHLD and SIGPIPE
    var sig_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sig_action, null);
    std.posix.sigaction(std.posix.SIG.PIPE, &sig_action, null);

    // Handle SIGINT/SIGTERM for clean shutdown
    const stop_action: std.posix.Sigaction = .{
        .handler = .{ .handler = signal_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &stop_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &stop_action, null);

    log.info("yabai.zig started (pid={d}, connection={d})", .{ pid, connection });

    return .{
        .skylight = sl,
        .connection = connection,
        .pid = pid,
        .layer_normal = layer_normal,
        .layer_below = layer_below,
        .layer_above = layer_above,
    };
}

/// Initialize SA client
pub fn initSAClient(sa_socket_path: []const u8) ?SAClient {
    log.debug("SA socket path: {s} (len={}, ptr={*})", .{ sa_socket_path, sa_socket_path.len, sa_socket_path.ptr });
    return SAClient.init(sa_socket_path);
}
