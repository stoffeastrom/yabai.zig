const std = @import("std");
const c = @import("../platform/c.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const ManagedHashMap = @import("ManagedHashMap.zig").ManagedHashMap;

const log = std.log.scoped(.window_table);

/// Central window registry - single source of truth for all window state.
/// All mutations go through this table, maintaining consistent indexes.
pub const WindowTable = @This();

/// Window entry with all tracked state
pub const Entry = struct {
    id: Window.Id,
    pid: std.posix.pid_t,
    space_id: Space.Id,
    ax_ref: c.AXUIElementRef,
    flags: Window.Flags = .{},

    /// Release CF resources (called automatically by ManagedHashMap)
    pub fn release(self: Entry) void {
        if (self.ax_ref != null) c.c.CFRelease(self.ax_ref);
    }
};

/// Cleanup function for ManagedHashMap
fn cleanupEntry(entry: Entry) void {
    entry.release();
}

// Primary storage (ManagedHashMap handles ax_ref cleanup)
allocator: std.mem.Allocator,
entries: ManagedHashMap(Window.Id, Entry, cleanupEntry) = undefined,

// Indexes (derived from entries, kept in sync - WindowList has no owned resources)
by_space: ManagedHashMap(Space.Id, WindowList, null) = undefined,
by_pid: ManagedHashMap(std.posix.pid_t, WindowList, null) = undefined,

// Focus state
focused_window_id: ?Window.Id = null,
last_focused_window_id: ?Window.Id = null,

/// Fixed-size list for index values (avoids allocations in hot path)
pub const WindowList = struct {
    items: [64]Window.Id = undefined,
    len: u8 = 0,

    pub fn append(self: *WindowList, wid: Window.Id) bool {
        if (self.len >= 64) return false;
        self.items[self.len] = wid;
        self.len += 1;
        return true;
    }

    pub fn remove(self: *WindowList, wid: Window.Id) bool {
        for (0..self.len) |i| {
            if (self.items[i] == wid) {
                // Shift remaining items
                for (i..self.len - 1) |j| {
                    self.items[j] = self.items[j + 1];
                }
                self.len -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn contains(self: *const WindowList, wid: Window.Id) bool {
        for (self.items[0..self.len]) |id| {
            if (id == wid) return true;
        }
        return false;
    }

    pub fn slice(self: *const WindowList) []const Window.Id {
        return self.items[0..self.len];
    }
};

pub fn init(allocator: std.mem.Allocator) WindowTable {
    return .{
        .allocator = allocator,
        .entries = ManagedHashMap(Window.Id, Entry, cleanupEntry).init(allocator),
        .by_space = ManagedHashMap(Space.Id, WindowList, null).init(allocator),
        .by_pid = ManagedHashMap(std.posix.pid_t, WindowList, null).init(allocator),
    };
}

pub fn deinit(self: *WindowTable) void {
    self.entries.deinit();
    self.by_space.deinit();
    self.by_pid.deinit();
}

// ============================================================================
// Mutations - all state changes go through these
// ============================================================================

/// Add a window to the table. Updates all indexes atomically.
/// ManagedHashMap handles ax_ref cleanup on overwrite.
pub fn addWindow(self: *WindowTable, entry: Entry) !void {
    // Check if already exists - need to update indexes
    if (self.entries.get(entry.id)) |old| {
        log.warn("addWindow: wid={d} already exists, updating", .{entry.id});

        if (old.space_id != entry.space_id) {
            self.removeFromSpaceIndex(old.space_id, entry.id);
            try self.addToSpaceIndex(entry.space_id, entry.id);
        }
        if (old.pid != entry.pid) {
            self.removeFromPidIndex(old.pid, entry.id);
            try self.addToPidIndex(entry.pid, entry.id);
        }
        // ManagedHashMap.put handles cleanup of old ax_ref
        try self.entries.put(entry.id, entry);
        return;
    }

    // Add to primary storage (ManagedHashMap)
    try self.entries.put(entry.id, entry);
    errdefer _ = self.entries.remove(entry.id);

    // Add to space index
    try self.addToSpaceIndex(entry.space_id, entry.id);
    errdefer self.removeFromSpaceIndex(entry.space_id, entry.id);

    // Add to pid index
    try self.addToPidIndex(entry.pid, entry.id);

    log.debug("addWindow: wid={d} pid={d} space={d}", .{ entry.id, entry.pid, entry.space_id });
}

/// Remove a window from the table. Updates all indexes atomically.
/// ManagedHashMap handles ax_ref cleanup.
pub fn removeWindow(self: *WindowTable, wid: Window.Id) ?Entry {
    // Get entry info before removal (for index cleanup)
    const entry = self.entries.get(wid) orelse return null;

    // Update indexes first
    self.removeFromSpaceIndex(entry.space_id, wid);
    self.removeFromPidIndex(entry.pid, wid);

    // Clear focus if this was focused
    if (self.focused_window_id == wid) {
        self.focused_window_id = null;
    }

    // ManagedHashMap.remove handles ax_ref cleanup
    _ = self.entries.remove(wid);

    log.debug("removeWindow: wid={d}", .{wid});
    return entry;
}

/// Move a window to a different space. Updates indexes atomically.
pub fn moveToSpace(self: *WindowTable, wid: Window.Id, new_space: Space.Id) bool {
    const entry = self.entries.getPtr(wid) orelse return false;
    const old_space = entry.space_id;

    if (old_space == new_space) return true;

    // Update indexes
    self.removeFromSpaceIndex(old_space, wid);
    self.addToSpaceIndex(new_space, wid) catch {
        // Rollback - add back to old space
        self.addToSpaceIndex(old_space, wid) catch {};
        return false;
    };

    // Update entry
    entry.space_id = new_space;

    log.debug("moveToSpace: wid={d} from={d} to={d}", .{ wid, old_space, new_space });
    return true;
}

/// Set focused window
pub fn setFocused(self: *WindowTable, wid: ?Window.Id) void {
    if (self.focused_window_id) |old| {
        if (old != wid) {
            self.last_focused_window_id = old;
        }
    }
    self.focused_window_id = wid;
}

/// Set minimized flag for a window
pub fn setMinimized(self: *WindowTable, wid: Window.Id, minimized: bool) void {
    if (self.getPtr(wid)) |entry| {
        entry.flags.minimized = minimized;
    }
}

/// Set hidden flag for a window
pub fn setHidden(self: *WindowTable, wid: Window.Id, hidden: bool) void {
    if (self.getPtr(wid)) |entry| {
        entry.flags.hidden = hidden;
    }
}

/// Set floating flag for a window
pub fn setFloating(self: *WindowTable, wid: Window.Id, floating: bool) void {
    if (self.getPtr(wid)) |entry| {
        entry.flags.floating = floating;
    }
}

/// Set sticky flag for a window
pub fn setSticky(self: *WindowTable, wid: Window.Id, sticky: bool) void {
    if (self.getPtr(wid)) |entry| {
        entry.flags.sticky = sticky;
    }
}

/// Set shadow flag for a window
pub fn setShadow(self: *WindowTable, wid: Window.Id, shadow: bool) void {
    if (self.getPtr(wid)) |entry| {
        entry.flags.shadow = shadow;
    }
}

// ============================================================================
// Queries
// ============================================================================

/// Get a window entry by ID (read-only to prevent direct field mutation)
/// Use mutation methods like moveToSpace(), setFlags() for changes
pub fn get(self: *const WindowTable, wid: Window.Id) ?Entry {
    return self.entries.get(wid);
}

/// Get mutable pointer - INTERNAL USE ONLY for flag updates
/// Space changes MUST go through moveToSpace() to maintain indexes
fn getPtr(self: *WindowTable, wid: Window.Id) ?*Entry {
    return self.entries.getPtr(wid);
}

/// Check if a window exists
pub fn contains(self: *const WindowTable, wid: Window.Id) bool {
    return self.entries.contains(wid);
}

/// Get all windows for a space (authoritative list)
pub fn getWindowsForSpace(self: *const WindowTable, space_id: Space.Id) []const Window.Id {
    if (self.by_space.getPtrConst(space_id)) |list| {
        return list.slice();
    }
    return &[_]Window.Id{};
}

/// Get all windows for a process
pub fn getWindowsForPid(self: *const WindowTable, pid: std.posix.pid_t) []const Window.Id {
    if (self.by_pid.getPtrConst(pid)) |list| {
        return list.slice();
    }
    return &[_]Window.Id{};
}

/// Get the focused window entry (read-only)
pub fn getFocused(self: *const WindowTable) ?Entry {
    const wid = self.focused_window_id orelse return null;
    return self.get(wid);
}

/// Get count of all windows
pub fn count(self: *const WindowTable) usize {
    return self.entries.count();
}

/// Get capacity of entries map
pub fn capacity(self: *const WindowTable) usize {
    return self.entries.capacity();
}

/// Get count of windows on a space
pub fn countForSpace(self: *const WindowTable, space_id: Space.Id) usize {
    if (self.by_space.getPtr(space_id)) |list| {
        return list.len;
    }
    return 0;
}

/// Get tileable windows for a space (not minimized, not floating, not hidden)
/// Returns allocated slice (caller must free)
pub fn getTileableWindowsForSpace(self: *WindowTable, allocator: std.mem.Allocator, space_id: Space.Id) ![]Window.Id {
    const all_windows = self.getWindowsForSpace(space_id);
    var result: std.ArrayList(Window.Id) = .empty;
    errdefer result.deinit(allocator);

    for (all_windows) |wid| {
        if (self.get(wid)) |entry| {
            if (!entry.flags.minimized and !entry.flags.floating and !entry.flags.hidden) {
                try result.append(allocator, wid);
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Swap the order of two windows in the space index (for window swapping)
pub fn swapWindowOrder(self: *WindowTable, wid_a: Window.Id, wid_b: Window.Id) void {
    // Get both entries to find their spaces
    const entry_a = self.entries.get(wid_a) orelse return;
    const entry_b = self.entries.get(wid_b) orelse return;

    // Only swap if on same space
    if (entry_a.space_id != entry_b.space_id) return;

    // Find and swap in the space index
    if (self.by_space.getPtr(entry_a.space_id)) |list| {
        var idx_a: ?usize = null;
        var idx_b: ?usize = null;

        for (list.items[0..list.len], 0..) |wid, i| {
            if (wid == wid_a) idx_a = i;
            if (wid == wid_b) idx_b = i;
        }

        if (idx_a != null and idx_b != null) {
            list.items[idx_a.?] = wid_b;
            list.items[idx_b.?] = wid_a;
            log.debug("swapWindowOrder: swapped {d} <-> {d}", .{ wid_a, wid_b });
        }
    }
}

/// Iterator over all entries
pub fn iterator(self: *WindowTable) std.AutoHashMapUnmanaged(Window.Id, Entry).Iterator {
    return self.entries.iterator();
}

// ============================================================================
// Index maintenance (internal)
// ============================================================================

fn addToSpaceIndex(self: *WindowTable, space_id: Space.Id, wid: Window.Id) !void {
    const result = try self.by_space.getOrPut(space_id);
    if (!result.found_existing) {
        result.value_ptr.* = .{};
    }
    if (!result.value_ptr.append(wid)) {
        log.warn("addToSpaceIndex: space={d} full (64 windows)", .{space_id});
    }
}

fn removeFromSpaceIndex(self: *WindowTable, space_id: Space.Id, wid: Window.Id) void {
    if (self.by_space.getPtr(space_id)) |list| {
        _ = list.remove(wid);
    }
}

fn addToPidIndex(self: *WindowTable, pid: std.posix.pid_t, wid: Window.Id) !void {
    const result = try self.by_pid.getOrPut(pid);
    if (!result.found_existing) {
        result.value_ptr.* = .{};
    }
    if (!result.value_ptr.append(wid)) {
        log.warn("addToPidIndex: pid={d} full (64 windows)", .{pid});
    }
}

fn removeFromPidIndex(self: *WindowTable, pid: std.posix.pid_t, wid: Window.Id) void {
    if (self.by_pid.getPtr(pid)) |list| {
        _ = list.remove(wid);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "WindowTable add/remove" {
    var table = WindowTable.init(std.testing.allocator);
    defer table.deinit();

    try table.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 200, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 300, .pid = 5678, .space_id = 2, .ax_ref = null });

    try std.testing.expectEqual(@as(usize, 3), table.count());
    try std.testing.expect(table.contains(100));
    try std.testing.expect(table.contains(200));
    try std.testing.expect(!table.contains(999));

    _ = table.removeWindow(100);
    try std.testing.expectEqual(@as(usize, 2), table.count());
    try std.testing.expect(!table.contains(100));
}

test "WindowTable space index" {
    var table = WindowTable.init(std.testing.allocator);
    defer table.deinit();

    try table.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 200, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 300, .pid = 5678, .space_id = 2, .ax_ref = null });

    const space1 = table.getWindowsForSpace(1);
    try std.testing.expectEqual(@as(usize, 2), space1.len);

    const space2 = table.getWindowsForSpace(2);
    try std.testing.expectEqual(@as(usize, 1), space2.len);
    try std.testing.expectEqual(@as(Window.Id, 300), space2[0]);

    const space3 = table.getWindowsForSpace(3);
    try std.testing.expectEqual(@as(usize, 0), space3.len);
}

test "WindowTable pid index" {
    var table = WindowTable.init(std.testing.allocator);
    defer table.deinit();

    try table.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 200, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 300, .pid = 5678, .space_id = 2, .ax_ref = null });

    const pid1 = table.getWindowsForPid(1234);
    try std.testing.expectEqual(@as(usize, 2), pid1.len);

    const pid2 = table.getWindowsForPid(5678);
    try std.testing.expectEqual(@as(usize, 1), pid2.len);
}

test "WindowTable moveToSpace" {
    var table = WindowTable.init(std.testing.allocator);
    defer table.deinit();

    try table.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });

    try std.testing.expectEqual(@as(usize, 1), table.getWindowsForSpace(1).len);
    try std.testing.expectEqual(@as(usize, 0), table.getWindowsForSpace(2).len);

    try std.testing.expect(table.moveToSpace(100, 2));

    try std.testing.expectEqual(@as(usize, 0), table.getWindowsForSpace(1).len);
    try std.testing.expectEqual(@as(usize, 1), table.getWindowsForSpace(2).len);

    // Entry should reflect new space
    try std.testing.expectEqual(@as(Space.Id, 2), table.get(100).?.space_id);
}

test "WindowTable focus tracking" {
    var table = WindowTable.init(std.testing.allocator);
    defer table.deinit();

    try table.addWindow(.{ .id = 100, .pid = 1234, .space_id = 1, .ax_ref = null });
    try table.addWindow(.{ .id = 200, .pid = 1234, .space_id = 1, .ax_ref = null });

    table.setFocused(100);
    try std.testing.expectEqual(@as(?Window.Id, 100), table.focused_window_id);

    table.setFocused(200);
    try std.testing.expectEqual(@as(?Window.Id, 200), table.focused_window_id);
    try std.testing.expectEqual(@as(?Window.Id, 100), table.last_focused_window_id);

    // Remove focused window should clear focus
    _ = table.removeWindow(200);
    try std.testing.expectEqual(@as(?Window.Id, null), table.focused_window_id);
}
