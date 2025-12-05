const std = @import("std");
const c = @import("../platform/c.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const geometry = @import("../core/geometry.zig");
const skylight = @import("../platform/skylight.zig");
const WindowTable = @import("WindowTable.zig");

const Point = geometry.Point;
const Rect = geometry.Rect;

pub const Windows = @This();

/// Focus-follows-mouse mode
pub const FfmMode = enum {
    disabled,
    autofocus,
    autoraise,
};

/// Purify mode (border drawing)
pub const PurifyMode = enum {
    disabled,
    managed,
    always,
};

/// Window origin mode (where new windows appear)
pub const WindowOriginMode = enum {
    default,
    focused,
    cursor,
};

/// Tracked window state (type alias for WindowTable.Entry)
pub const TrackedWindow = WindowTable.Entry;

/// Iterator over tracked windows
pub const EntryIterator = std.AutoHashMapUnmanaged(Window.Id, TrackedWindow).Iterator;

// ============================================================================
// Fields - all fields must come before methods
// ============================================================================

// Central window table (single source of truth) - use wrapper methods, not direct access
_table: WindowTable,

// Configuration (not in table)
ffm_mode: FfmMode = .disabled,
purify_mode: PurifyMode = .disabled,
window_origin_mode: WindowOriginMode = .default,
enable_mff: bool = false,
enable_window_opacity: bool = false,
active_window_opacity: f32 = 1.0,
normal_window_opacity: f32 = 0.9,
menubar_opacity: f32 = 1.0,

// ============================================================================
// Lifecycle
// ============================================================================

pub fn init(allocator: std.mem.Allocator) Windows {
    return .{ ._table = WindowTable.init(allocator) };
}

pub fn deinit(self: *Windows) void {
    self._table.deinit();
}

// ============================================================================
// Window mutations
// ============================================================================

/// Add a window to tracking
pub fn addWindow(self: *Windows, window: TrackedWindow) !void {
    try self._table.addWindow(window);
}

/// Remove a window from tracking
pub fn removeWindow(self: *Windows, wid: Window.Id) ?TrackedWindow {
    return self._table.removeWindow(wid);
}

/// Update space ID for a window
pub fn setWindowSpace(self: *Windows, wid: Window.Id, space_id: Space.Id) void {
    _ = self._table.moveToSpace(wid, space_id);
}

/// Set focused window
pub fn setFocused(self: *Windows, wid: ?Window.Id) void {
    self._table.setFocused(wid);
}

/// Set minimized flag for a window
pub fn setMinimized(self: *Windows, wid: Window.Id, minimized: bool) void {
    if (self._table.get(wid)) |entry| {
        entry.flags.minimized = minimized;
    }
}

/// Remove all windows for a given PID (returns count removed)
pub fn removeWindowsForPid(self: *Windows, pid: std.posix.pid_t) usize {
    const windows = self._table.getWindowsForPid(pid);
    if (windows.len == 0) return 0;

    // Copy IDs since we're modifying the collection
    var to_remove: [64]Window.Id = undefined;
    const remove_count = @min(windows.len, 64);
    @memcpy(to_remove[0..remove_count], windows[0..remove_count]);

    var removed: usize = 0;
    for (to_remove[0..remove_count]) |wid| {
        if (self._table.removeWindow(wid) != null) {
            removed += 1;
        }
    }
    return removed;
}

// ============================================================================
// Window queries
// ============================================================================

/// Get a tracked window by ID
pub fn getWindow(self: *Windows, wid: Window.Id) ?*TrackedWindow {
    return self._table.get(wid);
}

/// Get space ID for a window (from our tracking, not macOS)
pub fn getWindowSpace(self: *Windows, wid: Window.Id) ?Space.Id {
    const entry = self._table.get(wid) orelse return null;
    return if (entry.space_id != 0) entry.space_id else null;
}

/// Get the currently focused window
pub fn getFocused(self: *Windows) ?*TrackedWindow {
    return self._table.getFocused();
}

/// Get focused window ID
pub fn getFocusedId(self: *const Windows) ?Window.Id {
    return self._table.focused_window_id;
}

/// Get last focused window ID (before current focus)
pub fn getLastFocusedId(self: *const Windows) ?Window.Id {
    return self._table.last_focused_window_id;
}

/// Get all windows for a space (authoritative list from table)
pub fn getWindowsForSpace(self: *const Windows, space_id: Space.Id) []const Window.Id {
    return self._table.getWindowsForSpace(space_id);
}

/// Get tileable windows for a space (not minimized, not floating, not hidden)
/// Returns allocated slice (caller must free)
pub fn getTileableWindowsForSpace(self: *Windows, allocator: std.mem.Allocator, space_id: Space.Id) ![]Window.Id {
    return self._table.getTileableWindowsForSpace(allocator, space_id);
}

/// Swap the order of two windows in the space index (for window swapping)
pub fn swapWindowOrder(self: *Windows, wid_a: Window.Id, wid_b: Window.Id) void {
    self._table.swapWindowOrder(wid_a, wid_b);
}

/// Get all window IDs (allocates)
pub fn getWindowIds(self: *Windows, allocator: std.mem.Allocator) ![]Window.Id {
    var list = std.ArrayList(Window.Id).init(allocator);
    errdefer list.deinit();

    var it = self._table.iterator();
    while (it.next()) |entry| {
        try list.append(entry.key_ptr.*);
    }
    return list.toOwnedSlice();
}

/// Get windows for a specific process
pub fn getWindowsForPid(self: *const Windows, pid: std.posix.pid_t) []const Window.Id {
    return self._table.getWindowsForPid(pid);
}

/// Get count of tracked windows
pub fn count(self: *const Windows) usize {
    return self._table.count();
}

/// Get capacity of window table
pub fn capacity(self: *const Windows) usize {
    return self._table.capacity();
}

/// Check if window exists
pub fn contains(self: *const Windows, wid: Window.Id) bool {
    return self._table.contains(wid);
}

/// Iterator over all entries
pub fn iterator(self: *Windows) EntryIterator {
    return self._table.entries.iterator();
}

// ============================================================================
// Opacity management
// ============================================================================

/// Update window opacity based on focus state
pub fn updateOpacity(self: *Windows, wid: Window.Id) void {
    if (!self.enable_window_opacity) return;

    const opacity = if (self._table.focused_window_id == wid)
        self.active_window_opacity
    else
        self.normal_window_opacity;

    Window.setOpacity(wid, opacity) catch {};
}

/// Update all window opacities
pub fn updateAllOpacities(self: *Windows) void {
    if (!self.enable_window_opacity) return;

    var it = self._table.iterator();
    while (it.next()) |entry| {
        self.updateOpacity(entry.key_ptr.*);
    }
}

/// Set window opacity configuration
pub fn setWindowOpacityEnabled(self: *Windows, enabled: bool) void {
    self.enable_window_opacity = enabled;
    if (enabled) {
        self.updateAllOpacities();
    } else {
        // Reset all windows to full opacity
        var it = self._table.iterator();
        while (it.next()) |entry| {
            Window.setOpacity(entry.key_ptr.*, 1.0) catch {};
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Windows init/deinit" {
    var wm = Windows.init(std.testing.allocator);
    defer wm.deinit();

    try std.testing.expectEqual(@as(usize, 0), wm.count());
    try std.testing.expectEqual(@as(?Window.Id, null), wm.getFocusedId());
}

test "Windows add/remove windows" {
    var wm = Windows.init(std.testing.allocator);
    defer wm.deinit();

    const win1 = TrackedWindow{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null };
    const win2 = TrackedWindow{ .id = 200, .pid = 1234, .space_id = 1, .ax_ref = null };

    try wm.addWindow(win1);
    try wm.addWindow(win2);

    try std.testing.expectEqual(@as(usize, 2), wm.count());
    try std.testing.expect(wm.getWindow(100) != null);
    try std.testing.expect(wm.getWindow(200) != null);
    try std.testing.expect(wm.getWindow(300) == null);

    _ = wm.removeWindow(100);
    try std.testing.expectEqual(@as(usize, 1), wm.count());
    try std.testing.expect(wm.getWindow(100) == null);
}

test "Windows focus tracking" {
    var wm = Windows.init(std.testing.allocator);
    defer wm.deinit();

    const win1 = TrackedWindow{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null };
    const win2 = TrackedWindow{ .id = 200, .pid = 1234, .space_id = 1, .ax_ref = null };

    try wm.addWindow(win1);
    try wm.addWindow(win2);

    wm.setFocused(100);
    try std.testing.expectEqual(@as(?Window.Id, 100), wm.getFocusedId());
    try std.testing.expect(wm.getFocused() != null);
    try std.testing.expectEqual(@as(Window.Id, 100), wm.getFocused().?.id);

    wm.setFocused(200);
    try std.testing.expectEqual(@as(?Window.Id, 200), wm.getFocusedId());
    try std.testing.expectEqual(@as(?Window.Id, 100), wm.getLastFocusedId());
}

test "Windows getWindowsForSpace" {
    var wm = Windows.init(std.testing.allocator);
    defer wm.deinit();

    try wm.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });
    try wm.addWindow(.{ .id = 101, .pid = 1234, .space_id = 1, .ax_ref = null });
    try wm.addWindow(.{ .id = 200, .pid = 5678, .space_id = 2, .ax_ref = null });

    const space1_windows = wm.getWindowsForSpace(1);
    try std.testing.expectEqual(@as(usize, 2), space1_windows.len);

    const space2_windows = wm.getWindowsForSpace(2);
    try std.testing.expectEqual(@as(usize, 1), space2_windows.len);
}

test "Windows setWindowSpace" {
    var wm = Windows.init(std.testing.allocator);
    defer wm.deinit();

    try wm.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });

    try std.testing.expectEqual(@as(usize, 1), wm.getWindowsForSpace(1).len);
    try std.testing.expectEqual(@as(usize, 0), wm.getWindowsForSpace(2).len);

    wm.setWindowSpace(100, 2);

    try std.testing.expectEqual(@as(usize, 0), wm.getWindowsForSpace(1).len);
    try std.testing.expectEqual(@as(usize, 1), wm.getWindowsForSpace(2).len);
}
