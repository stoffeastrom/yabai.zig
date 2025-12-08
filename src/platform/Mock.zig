const std = @import("std");
const Platform = @import("Platform.zig").Platform;
const geometry = @import("../core/geometry.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Display = @import("../core/Display.zig");
const Record = @import("../events/Record.zig").Record;

/// Mock platform implementation for testing.
/// Maintains simulated state that can be manipulated by tests
/// or populated from recorded snapshots.
pub const Mock = struct {
    allocator: std.mem.Allocator,

    // Simulated state
    windows: std.AutoHashMapUnmanaged(Window.Id, WindowState),
    spaces: std.AutoHashMapUnmanaged(Space.Id, SpaceState),
    displays: std.AutoHashMapUnmanaged(Display.Id, DisplayState),
    apps: std.AutoHashMapUnmanaged(i32, AppState),

    // Global state
    focused_window_id: ?Window.Id = null,
    focused_pid: ?i32 = null,
    cursor_position: geometry.Point = .{ .x = 0, .y = 0 },

    // Command log for verification
    command_log: std.ArrayListUnmanaged(Command),

    const Self = @This();

    pub const WindowState = struct {
        frame: geometry.Rect,
        space_id: Space.Id,
        pid: i32,
        level: i32 = 0,
        is_minimized: bool = false,
        is_fullscreen: bool = false,
    };

    pub const SpaceState = struct {
        display_id: Display.Id,
        space_type: Record.SpaceType = .user,
        is_active: bool = false,
    };

    pub const DisplayState = struct {
        frame: geometry.Rect,
        active_space_id: Space.Id,
    };

    pub const AppState = struct {
        name: []const u8,
        bundle_id: ?[]const u8 = null,
        is_hidden: bool = false,
    };

    /// Command types for logging what was called
    pub const Command = union(enum) {
        set_window_frame: struct { window_id: Window.Id, frame: geometry.Rect },
        set_window_level: struct { window_id: Window.Id, level: i32 },
        set_window_opacity: struct { window_id: Window.Id, opacity: f32 },
        focus_window: Window.Id,
        minimize_window: Window.Id,
        close_window: Window.Id,
        focus_space: Space.Id,
        move_window_to_space: struct { window_id: Window.Id, space_id: Space.Id },
        create_space: Display.Id,
        destroy_space: Space.Id,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .windows = .empty,
            .spaces = .empty,
            .displays = .empty,
            .apps = .empty,
            .command_log = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free app strings
        var app_it = self.apps.iterator();
        while (app_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            if (entry.value_ptr.bundle_id) |bid| {
                self.allocator.free(bid);
            }
        }
        self.apps.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        self.spaces.deinit(self.allocator);
        self.displays.deinit(self.allocator);
        self.command_log.deinit(self.allocator);
    }

    /// Get a Platform interface backed by this Mock
    pub fn platform(self: *Self) Platform {
        return Platform{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // ========================================================================
    // State manipulation (for tests)
    // ========================================================================

    pub fn addWindow(self: *Self, window_id: Window.Id, state: WindowState) !void {
        try self.windows.put(self.allocator, window_id, state);
    }

    pub fn addSpace(self: *Self, space_id: Space.Id, state: SpaceState) !void {
        try self.spaces.put(self.allocator, space_id, state);
    }

    pub fn addDisplay(self: *Self, display_id: Display.Id, state: DisplayState) !void {
        try self.displays.put(self.allocator, display_id, state);
    }

    pub fn addApp(self: *Self, pid: i32, name: []const u8, bundle_id: ?[]const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const bid_copy = if (bundle_id) |bid| try self.allocator.dupe(u8, bid) else null;
        try self.apps.put(self.allocator, pid, .{
            .name = name_copy,
            .bundle_id = bid_copy,
        });
    }

    /// Get commands that were executed (for test assertions)
    pub fn getCommands(self: *const Self) []const Command {
        return self.command_log.items;
    }

    /// Clear command log
    pub fn clearCommands(self: *Self) void {
        self.command_log.clearRetainingCapacity();
    }

    // ========================================================================
    // VTable implementation
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

    fn getSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    // --- Window Queries ---

    fn getWindowFrame(ptr: *anyopaque, window_id: Window.Id) ?geometry.Rect {
        const self = getSelf(ptr);
        if (self.windows.get(window_id)) |w| return w.frame;
        return null;
    }

    fn getWindowSpace(ptr: *anyopaque, window_id: Window.Id) ?Space.Id {
        const self = getSelf(ptr);
        if (self.windows.get(window_id)) |w| return w.space_id;
        return null;
    }

    fn getWindowOwner(ptr: *anyopaque, window_id: Window.Id) ?i32 {
        const self = getSelf(ptr);
        if (self.windows.get(window_id)) |w| return w.pid;
        return null;
    }

    fn getWindowLevel(ptr: *anyopaque, window_id: Window.Id) ?i32 {
        const self = getSelf(ptr);
        if (self.windows.get(window_id)) |w| return w.level;
        return null;
    }

    fn isWindowMinimized(ptr: *anyopaque, window_id: Window.Id) bool {
        const self = getSelf(ptr);
        if (self.windows.get(window_id)) |w| return w.is_minimized;
        return false;
    }

    fn isWindowFullscreen(ptr: *anyopaque, window_id: Window.Id) bool {
        const self = getSelf(ptr);
        if (self.windows.get(window_id)) |w| return w.is_fullscreen;
        return false;
    }

    // --- Window Commands ---

    fn setWindowFrame(ptr: *anyopaque, window_id: Window.Id, frame: geometry.Rect) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .set_window_frame = .{ .window_id = window_id, .frame = frame } }) catch {};
        if (self.windows.getPtr(window_id)) |w| {
            w.frame = frame;
            return true;
        }
        return false;
    }

    fn setWindowLevel(ptr: *anyopaque, window_id: Window.Id, level: i32) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .set_window_level = .{ .window_id = window_id, .level = level } }) catch {};
        if (self.windows.getPtr(window_id)) |w| {
            w.level = level;
            return true;
        }
        return false;
    }

    fn setWindowOpacity(ptr: *anyopaque, window_id: Window.Id, opacity: f32) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .set_window_opacity = .{ .window_id = window_id, .opacity = opacity } }) catch {};
        return self.windows.contains(window_id);
    }

    fn focusWindow(ptr: *anyopaque, window_id: Window.Id) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .focus_window = window_id }) catch {};
        if (self.windows.contains(window_id)) {
            self.focused_window_id = window_id;
            return true;
        }
        return false;
    }

    fn minimizeWindow(ptr: *anyopaque, window_id: Window.Id) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .minimize_window = window_id }) catch {};
        if (self.windows.getPtr(window_id)) |w| {
            w.is_minimized = true;
            return true;
        }
        return false;
    }

    fn closeWindow(ptr: *anyopaque, window_id: Window.Id) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .close_window = window_id }) catch {};
        return self.windows.remove(window_id);
    }

    // --- Space Queries ---

    fn getSpaceType(ptr: *anyopaque, space_id: Space.Id) Record.SpaceType {
        const self = getSelf(ptr);
        if (self.spaces.get(space_id)) |s| return s.space_type;
        return .user;
    }

    fn getSpaceDisplay(ptr: *anyopaque, space_id: Space.Id) ?Display.Id {
        const self = getSelf(ptr);
        if (self.spaces.get(space_id)) |s| return s.display_id;
        return null;
    }

    fn getSpaceWindows(ptr: *anyopaque, allocator: std.mem.Allocator, space_id: Space.Id) ?[]Window.Id {
        const self = getSelf(ptr);
        var count: usize = 0;
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.space_id == space_id) count += 1;
        }
        if (count == 0) return null;

        var result = allocator.alloc(Window.Id, count) catch return null;
        var idx: usize = 0;
        it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.space_id == space_id) {
                result[idx] = entry.key_ptr.*;
                idx += 1;
            }
        }
        return result;
    }

    fn getActiveSpaceForDisplay(ptr: *anyopaque, display_id: Display.Id) ?Space.Id {
        const self = getSelf(ptr);
        if (self.displays.get(display_id)) |d| return d.active_space_id;
        return null;
    }

    // --- Space Commands ---

    fn focusSpace(ptr: *anyopaque, space_id: Space.Id) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .focus_space = space_id }) catch {};
        if (self.spaces.get(space_id)) |s| {
            if (self.displays.getPtr(s.display_id)) |d| {
                d.active_space_id = space_id;
                return true;
            }
        }
        return false;
    }

    fn moveWindowToSpace(ptr: *anyopaque, window_id: Window.Id, space_id: Space.Id) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .move_window_to_space = .{ .window_id = window_id, .space_id = space_id } }) catch {};
        if (self.windows.getPtr(window_id)) |w| {
            w.space_id = space_id;
            return true;
        }
        return false;
    }

    fn createSpace(ptr: *anyopaque, display_id: Display.Id) ?Space.Id {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .create_space = display_id }) catch {};
        // Generate a new space ID (simple incrementing)
        var max_id: Space.Id = 0;
        var it = self.spaces.keyIterator();
        while (it.next()) |key| {
            if (key.* > max_id) max_id = key.*;
        }
        const new_id = max_id + 1;
        self.spaces.put(self.allocator, new_id, .{
            .display_id = display_id,
            .space_type = .user,
        }) catch return null;
        return new_id;
    }

    fn destroySpace(ptr: *anyopaque, space_id: Space.Id) bool {
        const self = getSelf(ptr);
        self.command_log.append(self.allocator, .{ .destroy_space = space_id }) catch {};
        return self.spaces.remove(space_id);
    }

    // --- Display Queries ---

    fn getDisplayFrame(ptr: *anyopaque, display_id: Display.Id) ?geometry.Rect {
        const self = getSelf(ptr);
        if (self.displays.get(display_id)) |d| return d.frame;
        return null;
    }

    fn getDisplaySpaces(ptr: *anyopaque, allocator: std.mem.Allocator, display_id: Display.Id) ?[]Space.Id {
        const self = getSelf(ptr);
        var count: usize = 0;
        var it = self.spaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.display_id == display_id) count += 1;
        }
        if (count == 0) return null;

        var result = allocator.alloc(Space.Id, count) catch return null;
        var idx: usize = 0;
        it = self.spaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.display_id == display_id) {
                result[idx] = entry.key_ptr.*;
                idx += 1;
            }
        }
        return result;
    }

    fn getAllDisplays(ptr: *anyopaque, allocator: std.mem.Allocator) ?[]Display.Id {
        const self = getSelf(ptr);
        const count = self.displays.count();
        if (count == 0) return null;

        var result = allocator.alloc(Display.Id, count) catch return null;
        var idx: usize = 0;
        var it = self.displays.keyIterator();
        while (it.next()) |key| {
            result[idx] = key.*;
            idx += 1;
        }
        return result;
    }

    // --- App Queries ---

    fn getAppName(ptr: *anyopaque, allocator: std.mem.Allocator, pid: i32) ?[]const u8 {
        const self = getSelf(ptr);
        if (self.apps.get(pid)) |a| {
            return allocator.dupe(u8, a.name) catch null;
        }
        return null;
    }

    fn getAppBundleId(ptr: *anyopaque, allocator: std.mem.Allocator, pid: i32) ?[]const u8 {
        const self = getSelf(ptr);
        if (self.apps.get(pid)) |a| {
            if (a.bundle_id) |bid| {
                return allocator.dupe(u8, bid) catch null;
            }
        }
        return null;
    }

    fn isAppHidden(ptr: *anyopaque, pid: i32) bool {
        const self = getSelf(ptr);
        if (self.apps.get(pid)) |a| return a.is_hidden;
        return false;
    }

    // --- System ---

    fn getCursorPosition(ptr: *anyopaque) geometry.Point {
        const self = getSelf(ptr);
        return self.cursor_position;
    }

    fn getFocusedWindowId(ptr: *anyopaque) ?Window.Id {
        const self = getSelf(ptr);
        return self.focused_window_id;
    }

    fn getFocusedPid(ptr: *anyopaque) ?i32 {
        const self = getSelf(ptr);
        return self.focused_pid;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Mock basic window operations" {
    var mock = Mock.init(std.testing.allocator);
    defer mock.deinit();

    // Add a window
    try mock.addWindow(100, .{
        .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .space_id = 1,
        .pid = 1234,
    });

    const p = mock.platform();

    // Query window
    const frame = p.getWindowFrame(100);
    try std.testing.expect(frame != null);
    try std.testing.expectEqual(@as(f64, 800), frame.?.width);

    // Modify window
    try std.testing.expect(p.setWindowFrame(100, .{ .x = 10, .y = 10, .width = 400, .height = 300 }));

    // Verify change
    const new_frame = p.getWindowFrame(100);
    try std.testing.expectEqual(@as(f64, 400), new_frame.?.width);

    // Check command log
    try std.testing.expectEqual(@as(usize, 1), mock.getCommands().len);
}

test "Mock space operations" {
    var mock = Mock.init(std.testing.allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 1,
    });
    try mock.addSpace(1, .{ .display_id = 1, .is_active = true });
    try mock.addSpace(2, .{ .display_id = 1 });

    const p = mock.platform();

    // Create new space
    const new_id = p.createSpace(1);
    try std.testing.expect(new_id != null);
    try std.testing.expectEqual(@as(Space.Id, 3), new_id.?);

    // Focus space
    try std.testing.expect(p.focusSpace(2));
    try std.testing.expectEqual(@as(?Space.Id, 2), p.getActiveSpaceForDisplay(1));
}

test "Mock move window to space" {
    var mock = Mock.init(std.testing.allocator);
    defer mock.deinit();

    try mock.addSpace(1, .{ .display_id = 1 });
    try mock.addSpace(2, .{ .display_id = 1 });
    try mock.addWindow(100, .{
        .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .space_id = 1,
        .pid = 1234,
    });

    const p = mock.platform();

    try std.testing.expectEqual(@as(?Space.Id, 1), p.getWindowSpace(100));
    try std.testing.expect(p.moveWindowToSpace(100, 2));
    try std.testing.expectEqual(@as(?Space.Id, 2), p.getWindowSpace(100));
}
