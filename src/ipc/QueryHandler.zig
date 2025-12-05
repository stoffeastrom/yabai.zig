///! Query handlers for IPC --query commands
///!
///! Handles: displays, spaces, windows queries
const std = @import("std");
const c = @import("../platform/c.zig");
const skylight = @import("../platform/skylight.zig");
const Server = @import("Server.zig");
const Response = @import("Response.zig");
const Display = @import("../core/Display.zig");
const Displays = @import("../state/Displays.zig");

/// Context needed for query operations
pub const Context = struct {
    allocator: std.mem.Allocator,
    skylight: *const skylight.SkyLight,
    connection: c_int,
    displays: *Displays,
};

/// Query displays and return JSON
pub fn queryDisplays(ctx: Context, client_fd: std.posix.socket_t) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Get all displays
    const displays = Displays.getActiveDisplayList(ctx.allocator) catch {
        Server.sendErr(client_fd, Response.err(.display_not_found));
        return;
    };
    defer ctx.allocator.free(displays);

    writer.writeByte('[') catch return;

    for (displays, 0..) |did, i| {
        if (i > 0) writer.writeByte(',') catch return;

        const bounds = Display.getBounds(did);
        const is_main = (did == Displays.getMainDisplayId());
        const label = ctx.displays.getLabelForDisplay(did) orelse "";

        // Get spaces for display
        const spaces = Display.getSpaceList(ctx.allocator, did) catch &[_]u64{};
        defer if (spaces.len > 0) ctx.allocator.free(spaces);

        writer.print(
            \\{{"id":{d},"uuid":"","index":{d},"label":"{s}","frame":{{"x":{d:.4},"y":{d:.4},"w":{d:.4},"h":{d:.4}}},"spaces":[
        , .{
            did,
            i + 1,
            label,
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
        }) catch return;

        for (spaces, 0..) |sid, j| {
            if (j > 0) writer.writeByte(',') catch return;
            writer.print("{d}", .{sid}) catch return;
        }

        writer.print("]," ++
            \\"has-focus":{s}}}
        , .{if (is_main) "true" else "false"}) catch return;
    }

    writer.writeByte(']') catch return;
    writer.writeByte('\n') catch return;

    Server.sendResponse(client_fd, fbs.getWritten());
}

/// Query spaces and return JSON
pub fn querySpaces(ctx: Context, client_fd: std.posix.socket_t) void {
    var buf: [16384]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const displays = Displays.getActiveDisplayList(ctx.allocator) catch {
        Server.sendErr(client_fd, Response.err(.display_not_found));
        return;
    };
    defer ctx.allocator.free(displays);

    writer.writeByte('[') catch return;
    var first = true;

    for (displays, 0..) |did, display_idx| {
        const spaces = Display.getSpaceList(ctx.allocator, did) catch continue;
        defer if (spaces.len > 0) ctx.allocator.free(spaces);

        const current_space = Display.getCurrentSpace(did);

        for (spaces, 0..) |sid, space_idx| {
            if (!first) writer.writeByte(',') catch return;
            first = false;

            const is_visible = if (current_space) |cs| cs == sid else false;

            writer.print(
                \\{{"id":{d},"uuid":"","index":{d},"label":"","type":"user","display":{d},"windows":[],"first-window":0,"last-window":0,"has-focus":{s},"is-visible":{s},"is-native-fullscreen":false}}
            , .{
                sid,
                space_idx + 1,
                display_idx + 1,
                if (is_visible) "true" else "false",
                if (is_visible) "true" else "false",
            }) catch return;
        }
    }

    writer.writeByte(']') catch return;
    writer.writeByte('\n') catch return;

    Server.sendResponse(client_fd, fbs.getWritten());
}

/// Query windows and return JSON
pub fn queryWindows(ctx: Context, client_fd: std.posix.socket_t) void {
    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const sl = ctx.skylight;
    const cid = ctx.connection;

    // Get all displays and their spaces
    const displays = Displays.getActiveDisplayList(ctx.allocator) catch {
        Server.sendErr(client_fd, Response.err(.display_not_found));
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

    writer.writeByte('[') catch return;
    var first = true;

    while (sl.SLSWindowIteratorAdvance(iterator)) {
        const wid = sl.SLSWindowIteratorGetWindowID(iterator);
        const level = sl.SLSWindowIteratorGetLevel(iterator);
        const tags = sl.SLSWindowIteratorGetTags(iterator);
        _ = tags;

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

        if (!first) writer.writeByte(',') catch return;
        first = false;

        writer.print(
            \\{{"id":{d},"pid":{d},"app":"{s}","title":"","frame":{{"x":{d:.4},"y":{d:.4},"w":{d:.4},"h":{d:.4}}},"level":{d},"opacity":{d:.4},"is-visible":true}}
        , .{
            wid,
            pid,
            app_name,
            bounds.origin.x,
            bounds.origin.y,
            bounds.size.width,
            bounds.size.height,
            level,
            alpha,
        }) catch return;
    }

    writer.writeByte(']') catch return;
    writer.writeByte('\n') catch return;

    Server.sendResponse(client_fd, fbs.getWritten());
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
