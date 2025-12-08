//! Type definitions for Daemon - dirty flags, queues, and SA capabilities
const std = @import("std");
const c = @import("../platform/c.zig");
const sa_extractor = @import("../sa/extractor.zig");
const geometry = @import("../core/geometry.zig");

pub const MAXLEN = 512;

/// SA (Scripting Addition) capabilities discovered at runtime
pub const SACapabilities = struct {
    /// Whether SA functions were discovered successfully
    available: bool = false,
    /// Number of functions discovered (out of 7)
    discovered_count: usize = 0,
    /// Individual function availability
    can_add_space: bool = false,
    can_remove_space: bool = false,
    can_move_space: bool = false,
    can_focus_window: bool = false,
    /// Discovered function addresses (for future use)
    discovery: ?sa_extractor.DiscoveryResult = null,
};

/// Dirty state flags - accumulated during event handling, processed once per loop tick
pub const DirtyFlags = packed struct(u32) {
    // Layout flags
    /// Need to apply layout to current space
    layout_current: bool = false,
    /// Need to apply layout to all visible spaces
    layout_all: bool = false,
    /// Need to rebuild BSP tree (not just reapply)
    rebuild_view: bool = false,

    // Sync flags
    /// Need to rescan running applications
    scan_apps: bool = false,
    /// Need to sync space labels with config
    sync_spaces: bool = false,
    /// Need to sync config to state
    sync_config: bool = false,

    // Validation flags
    /// Need to validate all state (remove stale, refresh from macOS)
    validate_state: bool = false,
    /// Need to refresh window-to-space mappings from macOS
    refresh_window_spaces: bool = false,

    // Pending app events (queued PIDs processed in batch)
    /// One or more apps launched - need to track them
    apps_launched: bool = false,
    /// One or more apps terminated - need to clean up
    apps_terminated: bool = false,
    /// App front switched - need to update focus tracking
    app_focus_changed: bool = false,
    /// One or more apps hidden
    apps_hidden: bool = false,
    /// One or more apps shown
    apps_shown: bool = false,

    /// Reserved for future use
    _padding: u19 = 0,

    /// Check if any work is pending
    pub fn any(self: DirtyFlags) bool {
        return @as(u32, @bitCast(self)) != 0;
    }

    /// Clear all flags
    pub fn clear(self: *DirtyFlags) void {
        self.* = .{};
    }
};

/// Dirty space tracking - which spaces need layout
pub const DirtySpaces = struct {
    /// Spaces that need layout (by space ID)
    spaces: [16]u64 = [_]u64{0} ** 16,
    count: u8 = 0,

    /// Mark a space as needing layout
    pub fn mark(self: *DirtySpaces, space_id: u64) void {
        // Check if already marked
        for (self.spaces[0..self.count]) |sid| {
            if (sid == space_id) return;
        }
        // Add if room
        if (self.count < self.spaces.len) {
            self.spaces[self.count] = space_id;
            self.count += 1;
        }
    }

    /// Check if a space is marked dirty
    pub fn isDirty(self: *const DirtySpaces, space_id: u64) bool {
        for (self.spaces[0..self.count]) |sid| {
            if (sid == space_id) return true;
        }
        return false;
    }

    /// Clear all marked spaces
    pub fn clear(self: *DirtySpaces) void {
        self.count = 0;
    }

    /// Check if any spaces are dirty
    pub fn any(self: *const DirtySpaces) bool {
        return self.count > 0;
    }
};

/// Queue for pending PID events - fixed size ring buffer
pub const PidQueue = struct {
    pids: [32]c.pid_t = [_]c.pid_t{0} ** 32,
    count: u8 = 0,

    /// Add a PID to the queue (deduplicates)
    pub fn push(self: *PidQueue, pid: c.pid_t) void {
        // Check if already queued
        for (self.pids[0..self.count]) |p| {
            if (p == pid) return;
        }
        // Add if room
        if (self.count < self.pids.len) {
            self.pids[self.count] = pid;
            self.count += 1;
        }
    }

    /// Get all queued PIDs and clear
    pub fn drain(self: *PidQueue) []const c.pid_t {
        const result = self.pids[0..self.count];
        self.count = 0;
        return result;
    }

    /// Check if any PIDs are queued
    pub fn any(self: *const PidQueue) bool {
        return self.count > 0;
    }

    /// Clear the queue
    pub fn clear(self: *PidQueue) void {
        self.count = 0;
    }
};

/// Startup window move plan entry
pub const WindowMove = struct {
    wid: u32,
    from_space: u64,
    to_space: u64,
};

/// Stats from sync operation
pub const SyncStats = struct {
    moves: usize = 0,
    created: usize = 0,
    destroyed: usize = 0,
};

/// Result from sync space count operation
pub const SpaceCountResult = struct {
    created: usize = 0,
    destroyed: usize = 0,
};

/// Target state for space sync
pub const TargetState = struct {
    /// For each display, which space labels should be there
    /// Index is display index (0 = first display), value is list of labels
    display_labels: [8][16]?[]const u8 = [_][16]?[]const u8{[_]?[]const u8{null} ** 16} ** 8,
    display_label_count: [8]usize = [_]usize{0} ** 8,
    display_ids: [8]u32 = [_]u32{0} ** 8,
    display_count: usize = 0,
    /// Fallback display index for labels from missing displays
    fallback_display: usize = 0,
    /// Track which config space labels have been assigned
    assigned_labels: std.StaticBitSet(64) = std.StaticBitSet(64).initEmpty(),
};

/// Window info for queries
pub const WindowInfo = struct {
    id: u32,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

/// IPC handler context - passed to command/query handlers
pub const HandlerContext = struct {
    daemon: *anyopaque,
    apply_layout_fn: *const fn (*anyopaque, u64) void,
    get_bounds_fn: *const fn (*anyopaque, u64) ?geometry.Rect,
    mark_dirty_fn: *const fn (*anyopaque, u64) void,
};
