const std = @import("std");
const c = @import("../platform/c.zig");
const Application = @import("../core/Application.zig");
const ManagedHashMap = @import("ManagedHashMap.zig").ManagedHashMap;

pub const Apps = @This();

/// Tracked application state
pub const TrackedApp = struct {
    pid: Application.Pid,
    ax_ref: c.AXUIElementRef,
    observer: ?c.c.AXObserverRef = null,
    notification_mask: Application.NotificationMask = .{},
    is_observing: bool = false,
    is_hidden: bool = false,

    /// Release CF resources (called automatically by ManagedHashMap)
    pub fn release(self: TrackedApp) void {
        if (self.observer) |obs| {
            Application.removeObserverFromRunLoop(obs);
            c.c.CFRelease(obs);
        }
        if (self.ax_ref != null) c.c.CFRelease(self.ax_ref);
    }
};

/// Cleanup function for ManagedHashMap
fn cleanupTrackedApp(app: TrackedApp) void {
    app.release();
}

// State
allocator: std.mem.Allocator,
applications: ManagedHashMap(Application.Pid, TrackedApp, cleanupTrackedApp) = undefined,
frontmost_pid: ?Application.Pid = null,

pub fn init(allocator: std.mem.Allocator) Apps {
    return .{
        .allocator = allocator,
        .applications = ManagedHashMap(Application.Pid, TrackedApp, cleanupTrackedApp).init(allocator),
    };
}

pub fn deinit(self: *Apps) void {
    // ManagedHashMap auto-releases all TrackedApps
    self.applications.deinit();
}

/// Add an application to tracking (ManagedHashMap handles cleanup on overwrite)
pub fn addApplication(self: *Apps, app: TrackedApp) !void {
    try self.applications.put(app.pid, app);
}

/// Remove an application from tracking (ManagedHashMap handles cleanup)
pub fn removeApplication(self: *Apps, pid: Application.Pid) bool {
    if (self.frontmost_pid == pid) self.frontmost_pid = null;
    return self.applications.remove(pid);
}

/// Get a tracked application by PID
pub fn getApplication(self: *Apps, pid: Application.Pid) ?*TrackedApp {
    return self.applications.getPtr(pid);
}

/// Get the frontmost application
pub fn getFrontmost(self: *Apps) ?*TrackedApp {
    const pid = self.frontmost_pid orelse return null;
    return self.getApplication(pid);
}

/// Set frontmost application
pub fn setFrontmost(self: *Apps, pid: ?Application.Pid) void {
    self.frontmost_pid = pid;
}

/// Get all PIDs (allocates)
pub fn getAllPids(self: *Apps, allocator: std.mem.Allocator) ![]Application.Pid {
    var list = std.ArrayList(Application.Pid){};
    errdefer list.deinit(allocator);

    var it = self.applications.keyIterator();
    while (it.next()) |key| {
        try list.append(allocator, key.*);
    }
    return list.toOwnedSlice(allocator);
}

/// Get count of tracked applications
pub fn count(self: *Apps) usize {
    return self.applications.count();
}

/// Get capacity of applications map
pub fn capacity(self: *const Apps) usize {
    return self.applications.capacity();
}

/// Start observing an application
pub fn startObserving(self: *Apps, pid: Application.Pid, callback: c.accessibility.ObserverCallback, context: ?*anyopaque) !void {
    const app = self.getApplication(pid) orelse return;
    if (app.is_observing) return;

    const observer = try Application.createObserver(pid, callback);
    errdefer c.c.CFRelease(observer);

    Application.observeAll(observer, app.ax_ref, context) catch |err| {
        c.c.CFRelease(observer);
        return err;
    };

    Application.addObserverToRunLoop(observer);
    app.observer = observer;
    app.is_observing = true;
}

/// Stop observing an application
pub fn stopObserving(self: *Apps, pid: Application.Pid) void {
    const app = self.getApplication(pid) orelse return;
    if (!app.is_observing) return;

    if (app.observer) |obs| {
        Application.removeObserverFromRunLoop(obs);
        c.c.CFRelease(obs);
        app.observer = null;
    }
    app.is_observing = false;
}

// ============================================================================
// Tests
// ============================================================================

test "Apps init/deinit" {
    var am = Apps.init(std.testing.allocator);
    defer am.deinit();

    try std.testing.expectEqual(@as(usize, 0), am.count());
    try std.testing.expectEqual(@as(?Application.Pid, null), am.frontmost_pid);
}

test "Apps add/remove applications" {
    var am = Apps.init(std.testing.allocator);
    defer am.deinit();

    const app1 = TrackedApp{ .pid = 1234, .ax_ref = null };
    const app2 = TrackedApp{ .pid = 5678, .ax_ref = null };

    try am.addApplication(app1);
    try am.addApplication(app2);

    try std.testing.expectEqual(@as(usize, 2), am.count());
    try std.testing.expect(am.getApplication(1234) != null);
    try std.testing.expect(am.getApplication(5678) != null);
    try std.testing.expect(am.getApplication(9999) == null);

    _ = am.removeApplication(1234);
    try std.testing.expectEqual(@as(usize, 1), am.count());
    try std.testing.expect(am.getApplication(1234) == null);
}

test "Apps frontmost tracking" {
    var am = Apps.init(std.testing.allocator);
    defer am.deinit();

    try am.addApplication(.{ .pid = 1234, .ax_ref = null });
    try am.addApplication(.{ .pid = 5678, .ax_ref = null });

    am.setFrontmost(1234);
    try std.testing.expectEqual(@as(?Application.Pid, 1234), am.frontmost_pid);
    try std.testing.expect(am.getFrontmost() != null);
    try std.testing.expectEqual(@as(Application.Pid, 1234), am.getFrontmost().?.pid);

    am.setFrontmost(5678);
    try std.testing.expectEqual(@as(?Application.Pid, 5678), am.frontmost_pid);
}

test "Apps getAllPids" {
    var am = Apps.init(std.testing.allocator);
    defer am.deinit();

    try am.addApplication(.{ .pid = 100, .ax_ref = null });
    try am.addApplication(.{ .pid = 200, .ax_ref = null });
    try am.addApplication(.{ .pid = 300, .ax_ref = null });

    const pids = try am.getAllPids(std.testing.allocator);
    defer std.testing.allocator.free(pids);

    try std.testing.expectEqual(@as(usize, 3), pids.len);
}
