///! Query handlers for IPC --query commands
///!
///! Handles: displays, spaces, windows queries
const std = @import("std");
const c = @import("../platform/c.zig");
const skylight = @import("../platform/skylight.zig");
const Server = @import("Server.zig");
const Response = @import("Response.zig");
const Json = @import("Json.zig");
const Display = @import("../core/Display.zig");
const Displays = @import("../state/Displays.zig");
const Windows = @import("../state/Windows.zig");
const Spaces = @import("../state/Spaces.zig");

/// Context needed for query operations
pub const Context = struct {
    allocator: std.mem.Allocator,
    skylight: *const skylight.SkyLight,
    connection: c_int,
    displays: *Displays,
    windows: *Windows,
    spaces: *Spaces,
};

/// Send a JSON error response
fn sendJsonError(client_fd: std.posix.socket_t, code: []const u8, message: []const u8) void {
    var buf: [512]u8 = undefined;
    var w = Json.Writer.init(&buf);

    const err = Json.ErrorInfo{ .code = code, .message = message };
    err.write(&w) catch return;
    w.newline() catch return;

    Server.sendFailure(client_fd, w.getWritten());
}

/// Query displays and return JSON
pub fn queryDisplays(ctx: Context, client_fd: std.posix.socket_t) void {
    var buf: [16384]u8 = undefined;
    var w = Json.Writer.init(&buf);

    // Get all displays
    const displays = Displays.getActiveDisplayList(ctx.allocator) catch {
        sendJsonError(client_fd, "display_not_found", "no displays found");
        return;
    };
    defer ctx.allocator.free(displays);

    const main_display = Displays.getMainDisplayId();

    w.beginArray() catch return;

    for (displays, 0..) |did, i| {
        if (i > 0) w.comma() catch return;

        const bounds = Display.getBounds(did);
        const label = ctx.displays.getLabelForDisplay(did) orelse "";
        const spaces = Display.getSpaceList(ctx.allocator, did) catch &[_]u64{};
        defer if (spaces.len > 0) ctx.allocator.free(spaces);

        const info = Json.DisplayInfo{
            .id = did,
            .index = @intCast(i + 1),
            .label = label,
            .frame = .{
                .x = bounds.x,
                .y = bounds.y,
                .w = bounds.width,
                .h = bounds.height,
            },
            .spaces = spaces,
            .has_focus = (did == main_display),
        };
        info.write(&w) catch return;
    }

    w.endArray() catch return;
    w.newline() catch return;

    Server.sendResponse(client_fd, w.getWritten());
}

/// Query spaces and return JSON
pub fn querySpaces(ctx: Context, client_fd: std.posix.socket_t) void {
    var buf: [16384]u8 = undefined;
    var w = Json.Writer.init(&buf);

    const displays = Displays.getActiveDisplayList(ctx.allocator) catch {
        sendJsonError(client_fd, "display_not_found", "no displays found");
        return;
    };
    defer ctx.allocator.free(displays);

    w.beginArray() catch return;
    var first = true;

    for (displays, 0..) |did, display_idx| {
        const spaces = Display.getSpaceList(ctx.allocator, did) catch continue;
        defer if (spaces.len > 0) ctx.allocator.free(spaces);

        const current_space = Display.getCurrentSpace(did);
        const label = ctx.displays.getLabelForDisplay(did) orelse "";
        _ = label;

        for (spaces, 0..) |sid, space_idx| {
            if (!first) w.comma() catch return;
            first = false;

            const is_visible = if (current_space) |cs| cs == sid else false;
            const space_label = ctx.spaces.getLabelForSpace(sid) orelse "";

            const info = Json.SpaceInfo{
                .id = sid,
                .index = @intCast(space_idx + 1),
                .label = space_label,
                .display = @intCast(display_idx + 1),
                .has_focus = is_visible,
                .is_visible = is_visible,
            };
            info.write(&w) catch return;
        }
    }

    w.endArray() catch return;
    w.newline() catch return;

    Server.sendResponse(client_fd, w.getWritten());
}

/// Query windows and return JSON
pub fn queryWindows(ctx: Context, client_fd: std.posix.socket_t) void {
    var buf: [65536]u8 = undefined;
    var w = Json.Writer.init(&buf);

    const sl = ctx.skylight;
    const cid = ctx.connection;

    // Get all displays and their spaces
    const displays = Displays.getActiveDisplayList(ctx.allocator) catch {
        sendJsonError(client_fd, "display_not_found", "no displays found");
        return;
    };
    defer ctx.allocator.free(displays);

    // Collect all space IDs
    var all_spaces: std.ArrayList(u64) = .empty;
    defer all_spaces.deinit(ctx.allocator);

    for (displays) |did| {
        const spaces = Display.getSpaceList(ctx.allocator, did) catch continue;
        defer if (spaces.len > 0) ctx.allocator.free(spaces);
        for (spaces) |sid| {
            all_spaces.append(ctx.allocator, sid) catch continue;
        }
    }

    if (all_spaces.items.len == 0) {
        Server.sendResponse(client_fd, "[]\n");
        return;
    }

    // Create CFArray of space IDs
    const space_numbers = ctx.allocator.alloc(c.c.CFNumberRef, all_spaces.items.len) catch {
        Server.sendResponse(client_fd, "[]\n");
        return;
    };
    defer ctx.allocator.free(space_numbers);

    for (all_spaces.items, 0..) |sid, i| {
        var sid_copy = sid;
        space_numbers[i] = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &sid_copy);
    }
    defer for (space_numbers) |num| c.c.CFRelease(num);

    const space_array = c.c.CFArrayCreate(null, @ptrCast(space_numbers.ptr), @intCast(space_numbers.len), &c.c.kCFTypeArrayCallBacks);
    if (space_array == null) {
        Server.sendResponse(client_fd, "[]\n");
        return;
    }
    defer c.c.CFRelease(space_array);

    // Get windows for all spaces (options: 0x7 = include minimized)
    var set_tags: u64 = 0;
    var clear_tags: u64 = 0;
    const window_list = sl.SLSCopyWindowsWithOptionsAndTags(cid, 0, space_array, 0x7, &set_tags, &clear_tags);
    if (window_list == null) {
        Server.sendResponse(client_fd, "[]\n");
        return;
    }
    defer c.c.CFRelease(window_list);

    const window_count: usize = @intCast(c.c.CFArrayGetCount(window_list));
    if (window_count == 0) {
        Server.sendResponse(client_fd, "[]\n");
        return;
    }

    // Query detailed window info
    const query = sl.SLSWindowQueryWindows(cid, window_list, @intCast(window_count));
    if (query == null) {
        Server.sendResponse(client_fd, "[]\n");
        return;
    }
    defer c.c.CFRelease(query);

    const iterator = sl.SLSWindowQueryResultCopyWindows(query);
    if (iterator == null) {
        Server.sendResponse(client_fd, "[]\n");
        return;
    }
    defer c.c.CFRelease(iterator);

    w.beginArray() catch return;
    var first = true;

    while (sl.SLSWindowIteratorAdvance(iterator)) {
        const wid = sl.SLSWindowIteratorGetWindowID(iterator);
        const level = sl.SLSWindowIteratorGetLevel(iterator);

        // Get window bounds
        var bounds: c.CGRect = undefined;
        if (sl.SLSGetWindowBounds(cid, wid, &bounds) != 0) continue;

        // Get owner PID
        var owner_cid: c_int = 0;
        if (sl.SLSGetWindowOwner(cid, wid, &owner_cid) != 0) continue;

        var pid: c.pid_t = 0;
        _ = sl.SLSConnectionGetPID(owner_cid, &pid);

        // Get alpha
        var alpha: f32 = 1.0;
        _ = sl.SLSGetWindowAlpha(cid, wid, &alpha);

        // Get process name
        var proc_name: [256]u8 = undefined;
        const name_len = c.c.proc_name(pid, &proc_name, 256);
        const app_name = if (name_len > 0) proc_name[0..@intCast(name_len)] else "";

        if (!first) w.comma() catch return;
        first = false;

        const info = Json.WindowInfo{
            .id = wid,
            .pid = pid,
            .app = app_name,
            .frame = .{
                .x = bounds.origin.x,
                .y = bounds.origin.y,
                .w = bounds.size.width,
                .h = bounds.size.height,
            },
            .level = level,
            .opacity = alpha,
        };
        info.write(&w) catch return;
    }

    w.endArray() catch return;
    w.newline() catch return;

    Server.sendResponse(client_fd, w.getWritten());
}

/// Route query command to appropriate handler
pub fn handleQuery(ctx: Context, client_fd: std.posix.socket_t, args: []const u8) void {
    const target = std.mem.sliceTo(args, 0);

    if (std.mem.eql(u8, target, "--displays")) {
        queryDisplays(ctx, client_fd);
    } else if (std.mem.eql(u8, target, "--spaces")) {
        querySpaces(ctx, client_fd);
    } else if (std.mem.eql(u8, target, "--windows")) {
        queryWindows(ctx, client_fd);
    } else {
        Server.sendErr(client_fd, Response.err(.unknown_command));
    }
}

/// Parse query target from args (for testing)
pub fn parseQueryTarget(args: []const u8) ?QueryTarget {
    const target = std.mem.sliceTo(args, 0);

    if (std.mem.eql(u8, target, "--displays")) return .displays;
    if (std.mem.eql(u8, target, "--spaces")) return .spaces;
    if (std.mem.eql(u8, target, "--windows")) return .windows;
    return null;
}

pub const QueryTarget = enum {
    displays,
    spaces,
    windows,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseQueryTarget displays" {
    try testing.expectEqual(QueryTarget.displays, parseQueryTarget("--displays"));
}

test "parseQueryTarget spaces" {
    try testing.expectEqual(QueryTarget.spaces, parseQueryTarget("--spaces"));
}

test "parseQueryTarget windows" {
    try testing.expectEqual(QueryTarget.windows, parseQueryTarget("--windows"));
}

test "parseQueryTarget null-terminated" {
    // Simulate IPC message with null terminator
    const args = "--displays\x00--extra";
    try testing.expectEqual(QueryTarget.displays, parseQueryTarget(args));
}

test "parseQueryTarget invalid returns null" {
    try testing.expectEqual(@as(?QueryTarget, null), parseQueryTarget("--invalid"));
    try testing.expectEqual(@as(?QueryTarget, null), parseQueryTarget(""));
    try testing.expectEqual(@as(?QueryTarget, null), parseQueryTarget("displays")); // missing --
}
