const std = @import("std");
const c = @import("../platform/c.zig");
const skylight = @import("../platform/skylight.zig");

pub const Id = u64;

/// Space types from SkyLight
pub const Type = enum(c_int) {
    user = 0,
    system = 2,
    fullscreen = 4,

    pub fn fromInt(val: c_int) Type {
        return switch (val) {
            0 => .user,
            2 => .system,
            4 => .fullscreen,
            else => .user,
        };
    }
};

/// Errors that can occur during space operations
pub const Error = error{
    SkyLightError,
    InvalidSpace,
};

// ============================================================================
// Space operations using space ID (stateless)
// ============================================================================

/// Get display ID for space
pub fn getDisplayId(sid: Id) ?u32 {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    const uuid = sl.SLSCopyManagedDisplayForSpace(cid, sid);
    if (uuid == null) return null;
    defer c.c.CFRelease(uuid);

    // Get display ID from UUID
    return c.c.CGDisplayGetDisplayIDFromUUID(uuid);
}

/// Get display UUID for space. Caller must CFRelease.
pub fn getDisplayUUID(sid: Id) ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const uuid = sl.SLSCopyManagedDisplayForSpace(cid, sid);
    return if (uuid != null) uuid else null;
}

/// Get space type
pub fn getType(sid: Id) Type {
    const sl = skylight.get() catch return .user;
    const cid = sl.SLSMainConnectionID();
    return Type.fromInt(sl.SLSSpaceGetType(cid, sid));
}

/// Check if space is user space
pub fn isUser(sid: Id) bool {
    return getType(sid) == .user;
}

/// Check if space is system space
pub fn isSystem(sid: Id) bool {
    return getType(sid) == .system;
}

/// Check if space is fullscreen space
pub fn isFullscreen(sid: Id) bool {
    return getType(sid) == .fullscreen;
}

/// Check if space is currently visible
pub fn isVisible(sid: Id) bool {
    const sl = skylight.get() catch return false;
    const cid = sl.SLSMainConnectionID();

    // Get display for this space
    const uuid = sl.SLSCopyManagedDisplayForSpace(cid, sid);
    if (uuid == null) return false;
    defer c.c.CFRelease(uuid);

    // Check if this is the current space for that display
    const current = sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
    return current == sid;
}

/// Get space name. Caller must CFRelease.
pub fn getName(sid: Id) ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const name = sl.SLSSpaceCopyName(cid, sid);
    return if (name != null) name else null;
}

/// Get window list for space (allocates)
pub fn getWindowList(allocator: std.mem.Allocator, sid: Id, include_minimized: bool) ![]u32 {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    // Create space array
    var sid_val = sid;
    const sid_num = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &sid_val);
    if (sid_num == null) return error.SkyLightError;
    defer c.c.CFRelease(sid_num);

    const space_arr = c.c.CFArrayCreate(null, @ptrCast(@constCast(&sid_num)), 1, &c.c.kCFTypeArrayCallBacks);
    if (space_arr == null) return error.SkyLightError;
    defer c.c.CFRelease(space_arr);

    // Query windows
    var tags_include: u64 = 0;
    var tags_exclude: u64 = 0;
    if (!include_minimized) {
        tags_exclude = 0x2; // kCGWindowIsNotVisible
    }

    const windows = sl.SLSCopyWindowsWithOptionsAndTags(cid, 0, space_arr, 0x2, &tags_include, &tags_exclude);
    if (windows == null) return &[_]u32{};
    defer c.c.CFRelease(windows);

    const count: usize = @intCast(c.c.CFArrayGetCount(windows));
    if (count == 0) return &[_]u32{};

    const result = try allocator.alloc(u32, count);
    errdefer allocator.free(result);

    for (0..count) |i| {
        const num: c.c.CFNumberRef = @ptrCast(c.c.CFArrayGetValueAtIndex(windows, @intCast(i)));
        var wid: u32 = 0;
        _ = c.c.CFNumberGetValue(num, c.c.kCFNumberSInt32Type, &wid);
        result[i] = wid;
    }

    return result;
}

/// Move windows to space
pub fn moveWindows(wids: []const u32, sid: Id) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    // Create CFArray of window IDs
    var nums: [64]c.c.CFNumberRef = undefined;
    const count = @min(wids.len, 64);

    for (0..count) |i| {
        var wid = wids[i];
        nums[i] = c.c.CFNumberCreate(null, c.c.kCFNumberSInt32Type, &wid);
        if (nums[i] == null) {
            // Clean up already created
            for (0..i) |j| c.c.CFRelease(nums[j]);
            return error.SkyLightError;
        }
    }

    const arr = c.c.CFArrayCreate(null, @ptrCast(&nums), @intCast(count), &c.c.kCFTypeArrayCallBacks);

    // Clean up numbers
    for (0..count) |i| c.c.CFRelease(nums[i]);

    if (arr == null) return error.SkyLightError;
    defer c.c.CFRelease(arr);

    sl.SLSMoveWindowsToManagedSpace(cid, arr, sid);
}

/// Set current space for display
pub fn setCurrentSpace(display_uuid: c.CFStringRef, sid: Id) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    if (sl.SLSManagedDisplaySetCurrentSpace(cid, display_uuid, sid) != 0) return error.SkyLightError;
}

/// Show spaces
pub fn show(sids: []const Id) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    var nums: [64]c.c.CFNumberRef = undefined;
    const count = @min(sids.len, 64);

    for (0..count) |i| {
        var sid = sids[i];
        nums[i] = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &sid);
        if (nums[i] == null) {
            for (0..i) |j| c.c.CFRelease(nums[j]);
            return error.SkyLightError;
        }
    }

    const arr = c.c.CFArrayCreate(null, @ptrCast(&nums), @intCast(count), &c.c.kCFTypeArrayCallBacks);
    for (0..count) |i| c.c.CFRelease(nums[i]);

    if (arr == null) return error.SkyLightError;
    defer c.c.CFRelease(arr);

    if (sl.SLSShowSpaces(cid, arr) != 0) return error.SkyLightError;
}

/// Hide spaces
pub fn hide(sids: []const Id) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    var nums: [64]c.c.CFNumberRef = undefined;
    const count = @min(sids.len, 64);

    for (0..count) |i| {
        var sid = sids[i];
        nums[i] = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &sid);
        if (nums[i] == null) {
            for (0..i) |j| c.c.CFRelease(nums[j]);
            return error.SkyLightError;
        }
    }

    const arr = c.c.CFArrayCreate(null, @ptrCast(&nums), @intCast(count), &c.c.kCFTypeArrayCallBacks);
    for (0..count) |i| c.c.CFRelease(nums[i]);

    if (arr == null) return error.SkyLightError;
    defer c.c.CFRelease(arr);

    if (sl.SLSHideSpaces(cid, arr) != 0) return error.SkyLightError;
}

// ============================================================================
// Tests
// ============================================================================

test "Type enum values match SkyLight" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Type.user));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(Type.system));
    try std.testing.expectEqual(@as(c_int, 4), @intFromEnum(Type.fullscreen));
}

test "Type.fromInt handles known values" {
    try std.testing.expectEqual(Type.user, Type.fromInt(0));
    try std.testing.expectEqual(Type.system, Type.fromInt(2));
    try std.testing.expectEqual(Type.fullscreen, Type.fromInt(4));
}

test "Type.fromInt defaults to user for unknown values" {
    try std.testing.expectEqual(Type.user, Type.fromInt(99));
    try std.testing.expectEqual(Type.user, Type.fromInt(-1));
}
