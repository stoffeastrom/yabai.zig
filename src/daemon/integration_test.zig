//! Integration tests for Daemon using Mock platform
//!
//! These tests verify the daemon's behavior in response to events
//! without requiring real macOS APIs.

const std = @import("std");
const DaemonMod = @import("../Daemon.zig");
const Daemon = DaemonMod.Daemon;
const Mock = @import("../platform/Mock.zig").Mock;
const Platform = @import("../platform/Platform.zig").Platform;
const Event = @import("../events/Event.zig").Event;
const Config = @import("../config/Config.zig");
const geometry = @import("../core/geometry.zig");
const Windows = @import("../state/Windows.zig");

/// Test helper: create a daemon with mock platform
fn createTestDaemon(allocator: std.mem.Allocator, mock: *Mock) Daemon {
    return Daemon.initForTest(allocator, mock.platform());
}

// ============================================================================
// Window Tracking Tests
// ============================================================================

test "window creation adds to tracking" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    // Setup: one display, one space
    try mock.addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 100,
    });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });

    // Add window to mock (simulates what macOS would report)
    try mock.addWindow(500, .{
        .frame = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
        .space_id = 100,
        .pid = 1234,
    });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    // Process window created event
    daemon.processEvent(.{ .window_created = .{ .window_id = 500, .pid = 1234 } });

    // Verify window is tracked
    try std.testing.expectEqual(@as(usize, 1), daemon.windows.count());
    try std.testing.expect(daemon.windows.contains(500));

    const win = daemon.windows.getWindow(500);
    try std.testing.expect(win != null);
    try std.testing.expectEqual(@as(u64, 100), win.?.space_id);
}

test "window destruction removes from tracking" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 100,
    });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addWindow(500, .{
        .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .space_id = 100,
        .pid = 1234,
    });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    // Add window first
    daemon.processEvent(.{ .window_created = .{ .window_id = 500, .pid = 1234 } });
    try std.testing.expectEqual(@as(usize, 1), daemon.windows.count());

    // Destroy window
    daemon.processEvent(.{ .window_destroyed = .{ .window_id = 500 } });
    try std.testing.expectEqual(@as(usize, 0), daemon.windows.count());
    try std.testing.expect(!daemon.windows.contains(500));
}

test "window focus updates focused window" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 100,
    });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addWindow(500, .{ .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 }, .space_id = 100, .pid = 1234 });
    try mock.addWindow(501, .{ .frame = .{ .x = 100, .y = 100, .width = 800, .height = 600 }, .space_id = 100, .pid = 1234 });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    // Add windows
    daemon.processEvent(.{ .window_created = .{ .window_id = 500, .pid = 1234 } });
    daemon.processEvent(.{ .window_created = .{ .window_id = 501, .pid = 1234 } });

    // Focus first window
    daemon.processEvent(.{ .window_focused = .{ .window_id = 500 } });
    try std.testing.expectEqual(@as(?u32, 500), daemon.windows.getFocusedId());

    // Focus second window
    daemon.processEvent(.{ .window_focused = .{ .window_id = 501 } });
    try std.testing.expectEqual(@as(?u32, 501), daemon.windows.getFocusedId());
    try std.testing.expectEqual(@as(?u32, 500), daemon.windows.getLastFocusedId());
}

test "window minimize/deminimize updates flags" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 100,
    });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addWindow(500, .{ .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 }, .space_id = 100, .pid = 1234 });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    daemon.processEvent(.{ .window_created = .{ .window_id = 500, .pid = 1234 } });

    // Initially not minimized
    var win = daemon.windows.getWindow(500);
    try std.testing.expect(win != null);
    try std.testing.expect(!win.?.flags.minimized);

    // Minimize
    daemon.processEvent(.{ .window_minimized = .{ .window_id = 500 } });
    win = daemon.windows.getWindow(500);
    try std.testing.expect(win.?.flags.minimized);

    // Deminimize
    daemon.processEvent(.{ .window_deminimized = .{ .window_id = 500 } });
    win = daemon.windows.getWindow(500);
    try std.testing.expect(!win.?.flags.minimized);
}

// ============================================================================
// Multi-Space Tests
// ============================================================================

test "windows tracked per space" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    // Two displays, each with a space
    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 100 });
    try mock.addDisplay(2, .{ .frame = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 200 });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addSpace(200, .{ .display_id = 2, .space_type = .user, .is_active = true });

    // Windows on different spaces
    try mock.addWindow(500, .{ .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 }, .space_id = 100, .pid = 1000 });
    try mock.addWindow(501, .{ .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 }, .space_id = 100, .pid = 1000 });
    try mock.addWindow(600, .{ .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 }, .space_id = 200, .pid = 2000 });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    daemon.processEvent(.{ .window_created = .{ .window_id = 500, .pid = 1000 } });
    daemon.processEvent(.{ .window_created = .{ .window_id = 501, .pid = 1000 } });
    daemon.processEvent(.{ .window_created = .{ .window_id = 600, .pid = 2000 } });

    // Check windows per space
    const space100_windows = daemon.windows.getWindowsForSpace(100);
    const space200_windows = daemon.windows.getWindowsForSpace(200);

    try std.testing.expectEqual(@as(usize, 2), space100_windows.len);
    try std.testing.expectEqual(@as(usize, 1), space200_windows.len);
}

// ============================================================================
// Event Sequence Tests
// ============================================================================

test "rapid window create/destroy sequence" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 100 });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    // Rapid create/destroy (e.g., popup windows)
    for (0..10) |i| {
        const wid: u32 = @intCast(1000 + i);
        try mock.addWindow(wid, .{ .frame = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .space_id = 100, .pid = 1234 });
        daemon.processEvent(.{ .window_created = .{ .window_id = wid, .pid = 1234 } });
    }

    try std.testing.expectEqual(@as(usize, 10), daemon.windows.count());

    // Destroy all
    for (0..10) |i| {
        const wid: u32 = @intCast(1000 + i);
        daemon.processEvent(.{ .window_destroyed = .{ .window_id = wid } });
    }

    try std.testing.expectEqual(@as(usize, 0), daemon.windows.count());
}

test "focus changes don't affect untracked windows" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 100 });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });

    var daemon = createTestDaemon(allocator, &mock);
    defer daemon.deinit();

    // Focus event for untracked window should not crash
    daemon.processEvent(.{ .window_focused = .{ .window_id = 999 } });
    try std.testing.expectEqual(@as(?u32, 999), daemon.windows.getFocusedId());

    // But window itself is not tracked
    try std.testing.expect(!daemon.windows.contains(999));
}
