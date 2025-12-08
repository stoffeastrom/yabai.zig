const std = @import("std");
const Platform = @import("Platform.zig").Platform;
const geometry = @import("../core/geometry.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Display = @import("../core/Display.zig");
const Record = @import("../events/Record.zig").Record;
const skylight = @import("skylight.zig");
const ax = @import("accessibility.zig");
const c = @import("c.zig");
const SAClient = @import("../sa/client.zig").Client;

const log = std.log.scoped(.platform_real);

/// Real platform implementation - calls actual macOS APIs
pub const Real = struct {
    allocator: std.mem.Allocator,
    sl: *const skylight.SkyLight,
    connection: c_int,
    sa_client: ?*SAClient,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sa_client: ?*SAClient) !Self {
        const sl = try skylight.get();
        return Self{
            .allocator = allocator,
            .sl = sl,
            .connection = sl.SLSMainConnectionID(),
            .sa_client = sa_client,
        };
    }

    /// Get Platform interface
    pub fn platform(self: *Self) Platform {
        return Platform{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ========================================================================
    // Window Queries
    // ========================================================================

    fn getWindowFrame(ptr: *anyopaque, window_id: Window.Id) ?geometry.Rect {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var bounds: c.CGRect = undefined;
        if (self.sl.SLSGetWindowBounds(self.connection, window_id, &bounds) != 0) {
            return null;
        }
        return geometry.Rect.fromCG(bounds);
    }

    fn getWindowSpace(ptr: *anyopaque, window_id: Window.Id) ?Space.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Create CFArray with single window ID
        var wid = window_id;
        const wid_num = c.c.CFNumberCreate(null, c.c.kCFNumberSInt32Type, &wid);
        if (wid_num == null) return null;
        defer c.c.CFRelease(wid_num);

        var values = [_]?*const anyopaque{wid_num};
        const window_list = c.c.CFArrayCreate(null, @ptrCast(&values), 1, &c.c.kCFTypeArrayCallBacks);
        if (window_list == null) return null;
        defer c.c.CFRelease(window_list);

        // Query spaces for this window
        const spaces = self.sl.SLSCopySpacesForWindows(self.connection, 0x7, window_list);
        if (spaces == null) return null;
        defer c.c.CFRelease(spaces);

        const count = c.c.CFArrayGetCount(spaces);
        if (count == 0) return null;

        // Get first space ID
        const space_num: c.c.CFNumberRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces, 0));
        var space_id: u64 = 0;
        if (c.c.CFNumberGetValue(space_num, c.c.kCFNumberSInt64Type, &space_id) == 0) {
            return null;
        }

        return space_id;
    }

    fn getWindowOwner(ptr: *anyopaque, window_id: Window.Id) ?i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var owner_cid: c_int = undefined;
        if (self.sl.SLSGetWindowOwner(self.connection, window_id, &owner_cid) != 0) {
            return null;
        }

        var pid: c.pid_t = undefined;
        if (self.sl.SLSConnectionGetPID(owner_cid, &pid) != 0) {
            return null;
        }

        return pid;
    }

    fn getWindowLevel(ptr: *anyopaque, window_id: Window.Id) ?i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var level: c_int = undefined;
        if (self.sl.SLSGetWindowLevel(self.connection, window_id, &level) != 0) {
            return null;
        }
        return level;
    }

    fn isWindowMinimized(ptr: *anyopaque, window_id: Window.Id) bool {
        _ = ptr;
        _ = window_id;
        // Would need AX element to check - return false for now
        // In practice, Daemon tracks this via events
        return false;
    }

    fn isWindowFullscreen(ptr: *anyopaque, window_id: Window.Id) bool {
        _ = ptr;
        _ = window_id;
        // Would need AX element to check - return false for now
        return false;
    }

    // ========================================================================
    // Window Commands
    // ========================================================================

    fn setWindowFrame(ptr: *anyopaque, window_id: Window.Id, frame: geometry.Rect) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = window_id;
        _ = frame;
        // Window frame setting requires AX element reference
        // The Daemon uses Window.setFrame() which has the ax_ref
        // Platform abstraction would need the ax_ref passed in
        return false;
    }

    fn setWindowLevel(ptr: *anyopaque, window_id: Window.Id, level: i32) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.sa_client) |sa| {
            return sa.setWindowLayer(window_id, level);
        }
        return false;
    }

    fn setWindowOpacity(ptr: *anyopaque, window_id: Window.Id, opacity: f32) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sl.SLSSetWindowAlpha(self.connection, window_id, opacity) == 0;
    }

    fn focusWindow(ptr: *anyopaque, window_id: Window.Id) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.sa_client) |sa| {
            return sa.focusWindow(window_id);
        }
        return false;
    }

    fn minimizeWindow(ptr: *anyopaque, window_id: Window.Id) bool {
        _ = ptr;
        _ = window_id;
        // Requires AX element
        return false;
    }

    fn closeWindow(ptr: *anyopaque, window_id: Window.Id) bool {
        _ = ptr;
        _ = window_id;
        // Requires AX element
        return false;
    }

    // ========================================================================
    // Space Queries
    // ========================================================================

    fn getSpaceType(ptr: *anyopaque, space_id: Space.Id) Record.SpaceType {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const space_type = self.sl.SLSSpaceGetType(self.connection, space_id);
        return switch (space_type) {
            0 => .user,
            4 => .fullscreen,
            2 => .system,
            else => .user,
        };
    }

    fn getSpaceDisplay(ptr: *anyopaque, space_id: Space.Id) ?Display.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const uuid_str = self.sl.SLSCopyManagedDisplayForSpace(self.connection, space_id);
        if (uuid_str == null) return null;
        defer c.c.CFRelease(uuid_str);

        // Convert UUID string to display ID
        return displayIdFromUUID(uuid_str);
    }

    fn getSpaceWindows(ptr: *anyopaque, allocator: std.mem.Allocator, space_id: Space.Id) ?[]Window.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Create space array
        var sid_val = space_id;
        const sid_num = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &sid_val);
        if (sid_num == null) return null;
        defer c.c.CFRelease(sid_num);

        const space_arr = c.c.CFArrayCreate(null, @ptrCast(@constCast(&sid_num)), 1, &c.c.kCFTypeArrayCallBacks);
        if (space_arr == null) return null;
        defer c.c.CFRelease(space_arr);

        // Query windows (include minimized)
        var tags_include: u64 = 0;
        var tags_exclude: u64 = 0;

        const windows = self.sl.SLSCopyWindowsWithOptionsAndTags(self.connection, 0, space_arr, 0x2, &tags_include, &tags_exclude);
        if (windows == null) return null;
        defer c.c.CFRelease(windows);

        const count: usize = @intCast(c.c.CFArrayGetCount(windows));
        if (count == 0) return null;

        const result = allocator.alloc(Window.Id, count) catch return null;

        for (0..count) |i| {
            const num: c.c.CFNumberRef = @ptrCast(c.c.CFArrayGetValueAtIndex(windows, @intCast(i)));
            var wid: u32 = 0;
            _ = c.c.CFNumberGetValue(num, c.c.kCFNumberSInt32Type, &wid);
            result[i] = wid;
        }

        return result;
    }

    fn getActiveSpaceForDisplay(ptr: *anyopaque, display_id: Display.Id) ?Space.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Need to get display UUID first
        const displays = self.sl.SLSCopyManagedDisplays(self.connection);
        if (displays == null) return null;
        defer c.c.CFRelease(displays);

        const count = c.c.CFArrayGetCount(displays);
        var i: c_long = 0;
        while (i < count) : (i += 1) {
            const uuid_str: c.CFStringRef = @ptrCast(c.c.CFArrayGetValueAtIndex(displays, i));
            const did = displayIdFromUUID(uuid_str);
            if (did == display_id) {
                return self.sl.SLSManagedDisplayGetCurrentSpace(self.connection, uuid_str);
            }
        }

        return null;
    }

    // ========================================================================
    // Space Commands
    // ========================================================================

    fn focusSpace(ptr: *anyopaque, space_id: Space.Id) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.sa_client) |sa| {
            return sa.focusSpace(space_id);
        }
        return false;
    }

    fn moveWindowToSpace(ptr: *anyopaque, window_id: Window.Id, space_id: Space.Id) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.sa_client) |sa| {
            return sa.moveWindowToSpace(space_id, window_id);
        }
        return false;
    }

    fn createSpace(ptr: *anyopaque, display_id: Display.Id) ?Space.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Need current space on this display to create adjacent
        const current_space = getActiveSpaceForDisplay(ptr, display_id) orelse return null;

        if (self.sa_client) |sa| {
            return sa.createSpace(current_space);
        }
        return null;
    }

    fn destroySpace(ptr: *anyopaque, space_id: Space.Id) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.sa_client) |sa| {
            return sa.destroySpace(space_id);
        }
        return false;
    }

    // ========================================================================
    // Display Queries
    // ========================================================================

    fn getDisplayFrame(ptr: *anyopaque, display_id: Display.Id) ?geometry.Rect {
        _ = ptr;
        const bounds = c.c.CGDisplayBounds(display_id);
        return geometry.Rect.fromCG(bounds);
    }

    fn getDisplaySpaces(ptr: *anyopaque, allocator: std.mem.Allocator, display_id: Display.Id) ?[]Space.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const display_spaces = self.sl.SLSCopyManagedDisplaySpaces(self.connection);
        if (display_spaces == null) return null;
        defer c.c.CFRelease(display_spaces);

        const display_count = c.c.CFArrayGetCount(display_spaces);

        var i: c_long = 0;
        while (i < display_count) : (i += 1) {
            const display_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(display_spaces, i));
            const uuid_key = c.c.CFStringCreateWithCString(null, "Display Identifier", c.c.kCFStringEncodingUTF8);
            defer c.c.CFRelease(uuid_key);

            const uuid_str: c.CFStringRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, uuid_key));
            if (uuid_str == null) continue;

            const did = displayIdFromUUID(uuid_str);
            if (did != display_id) continue;

            // Found our display - get spaces
            const spaces_key = c.c.CFStringCreateWithCString(null, "Spaces", c.c.kCFStringEncodingUTF8);
            defer c.c.CFRelease(spaces_key);

            const spaces_array: c.CFArrayRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, spaces_key));
            if (spaces_array == null) continue;

            const space_count = c.c.CFArrayGetCount(spaces_array);
            if (space_count == 0) continue;

            const result = allocator.alloc(Space.Id, @intCast(space_count)) catch return null;
            var idx: usize = 0;

            var j: c_long = 0;
            while (j < space_count) : (j += 1) {
                const space_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces_array, j));
                const id_key = c.c.CFStringCreateWithCString(null, "id64", c.c.kCFStringEncodingUTF8);
                defer c.c.CFRelease(id_key);

                const id_num: c.c.CFNumberRef = @ptrCast(c.c.CFDictionaryGetValue(space_dict, id_key));
                if (id_num == null) continue;

                var space_id: u64 = 0;
                if (c.c.CFNumberGetValue(id_num, c.c.kCFNumberSInt64Type, &space_id) != 0) {
                    result[idx] = space_id;
                    idx += 1;
                }
            }

            if (idx > 0) {
                return result[0..idx];
            }

            allocator.free(result);
            return null;
        }

        return null;
    }

    fn getAllDisplays(ptr: *anyopaque, allocator: std.mem.Allocator) ?[]Display.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const displays = self.sl.SLSCopyManagedDisplays(self.connection);
        if (displays == null) return null;
        defer c.c.CFRelease(displays);

        const count = c.c.CFArrayGetCount(displays);
        if (count == 0) return null;

        const result = allocator.alloc(Display.Id, @intCast(count)) catch return null;

        var i: c_long = 0;
        var idx: usize = 0;
        while (i < count) : (i += 1) {
            const uuid_str: c.CFStringRef = @ptrCast(c.c.CFArrayGetValueAtIndex(displays, i));
            result[idx] = displayIdFromUUID(uuid_str);
            idx += 1;
        }

        return result[0..idx];
    }

    // ========================================================================
    // App Queries
    // ========================================================================

    fn getAppName(ptr: *anyopaque, allocator: std.mem.Allocator, pid: i32) ?[]const u8 {
        _ = ptr;
        _ = allocator;
        _ = pid;
        // Would need NSRunningApplication
        return null;
    }

    fn getAppBundleId(ptr: *anyopaque, allocator: std.mem.Allocator, pid: i32) ?[]const u8 {
        _ = ptr;
        _ = allocator;
        _ = pid;
        // Would need NSRunningApplication
        return null;
    }

    fn isAppHidden(ptr: *anyopaque, pid: i32) bool {
        _ = ptr;
        _ = pid;
        // Would need NSRunningApplication
        return false;
    }

    // ========================================================================
    // System
    // ========================================================================

    fn getCursorPosition(ptr: *anyopaque) geometry.Point {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var cursor: c.CGPoint = undefined;
        if (self.sl.SLSGetCurrentCursorLocation(self.connection, &cursor) == 0) {
            return geometry.Point.fromCG(cursor);
        }
        return .{ .x = 0, .y = 0 };
    }

    fn getFocusedWindowId(ptr: *anyopaque) ?Window.Id {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var cursor: c.CGPoint = undefined;
        if (self.sl.SLSGetCurrentCursorLocation(self.connection, &cursor) != 0) {
            return null;
        }

        var win_point: c.CGPoint = undefined;
        var wid: u32 = 0;
        var cid: c_int = 0;

        const result = self.sl.SLSFindWindowAndOwner(
            self.connection,
            3, // kCGWindowListOptionOnScreenOnly
            3,
            c.c.kCGWindowListExcludeDesktopElements,
            &cursor,
            &win_point,
            &wid,
            &cid,
        );

        if (result == 0 and wid != 0) {
            return wid;
        }

        return null;
    }

    fn getFocusedPid(ptr: *anyopaque) ?i32 {
        _ = ptr;
        // Would need NSWorkspace frontmostApplication
        return null;
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn displayIdFromUUID(uuid_str: c.CFStringRef) Display.Id {
        const uuid = c.c.CGDisplayGetDisplayIDFromUUID(c.c.CFUUIDCreateFromString(null, uuid_str));
        return uuid;
    }

    // ========================================================================
    // VTable
    // ========================================================================

    const vtable = Platform.VTable{
        .getWindowFrame = getWindowFrame,
        .getWindowSpace = getWindowSpace,
        .getWindowOwner = getWindowOwner,
        .getWindowLevel = getWindowLevel,
        .isWindowMinimized = isWindowMinimized,
        .isWindowFullscreen = isWindowFullscreen,
        .setWindowFrame = setWindowFrame,
        .setWindowLevel = setWindowLevel,
        .setWindowOpacity = setWindowOpacity,
        .focusWindow = focusWindow,
        .minimizeWindow = minimizeWindow,
        .closeWindow = closeWindow,
        .getSpaceType = getSpaceType,
        .getSpaceDisplay = getSpaceDisplay,
        .getSpaceWindows = getSpaceWindows,
        .getActiveSpaceForDisplay = getActiveSpaceForDisplay,
        .focusSpace = focusSpace,
        .moveWindowToSpace = moveWindowToSpace,
        .createSpace = createSpace,
        .destroySpace = destroySpace,
        .getDisplayFrame = getDisplayFrame,
        .getDisplaySpaces = getDisplaySpaces,
        .getAllDisplays = getAllDisplays,
        .getAppName = getAppName,
        .getAppBundleId = getAppBundleId,
        .isAppHidden = isAppHidden,
        .getCursorPosition = getCursorPosition,
        .getFocusedWindowId = getFocusedWindowId,
        .getFocusedPid = getFocusedPid,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "Real platform init" {
    var real = try Real.init(std.testing.allocator, null);
    const p = real.platform();

    // Should be able to get cursor position (may be negative with multiple displays)
    const pos = p.getCursorPosition();
    // Just verify we got valid floats, not that they're positive
    try std.testing.expect(!std.math.isNan(pos.x));
    try std.testing.expect(!std.math.isNan(pos.y));
}

test "Real platform getAllDisplays" {
    var real = try Real.init(std.testing.allocator, null);
    const p = real.platform();

    const displays = p.getAllDisplays(std.testing.allocator);
    if (displays) |d| {
        defer std.testing.allocator.free(d);
        try std.testing.expect(d.len >= 1);
    }
}
