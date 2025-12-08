//! Layout application functions for Daemon

const std = @import("std");
const c = @import("../platform/c.zig");
const Display = @import("../core/Display.zig");
const Displays = @import("../state/Displays.zig");
const Spaces = @import("../state/Spaces.zig");
const Windows = @import("../state/Windows.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const geometry = @import("../core/geometry.zig");
const Config = @import("../config/Config.zig");
const Platform = @import("../platform/Platform.zig").Platform;

const log = std.log.scoped(.daemon);

/// Get bounds for a space (display bounds minus padding and external bar)
pub fn getBoundsForSpace(
    platform: Platform,
    displays: *const Displays,
    config: *const Config,
    space_id: u64,
) ?geometry.Rect {
    const display_id = platform.getSpaceDisplay(space_id) orelse return null;
    var bounds = platform.getDisplayFrame(display_id) orelse return null;

    // Apply external bar (e.g., SketchyBar)
    const bar = config.external_bar;
    const apply_bar = switch (bar.position) {
        .off => false,
        .main => display_id == Displays.getMainDisplayId(),
        .all => true,
    };
    if (apply_bar) {
        bounds.y += @floatFromInt(bar.top_padding);
        bounds.height -= @floatFromInt(bar.top_padding + bar.bottom_padding);
    }

    _ = displays; // Display labels not needed for bounds calculation
    return bounds;
}

/// Apply layout to a specific space
pub fn applyLayoutToSpace(
    spaces: *Spaces,
    windows: *Windows,
    space_id: u64,
    bounds: geometry.Rect,
) void {
    spaces.applyLayout(space_id, bounds, windows) catch |err| {
        log.err("failed to apply layout to space {d}: {}", .{ space_id, err });
    };
}

/// Apply layout to all visible spaces (current space on each display)
pub fn applyAllSpaceLayouts(
    allocator: std.mem.Allocator,
    platform: Platform,
    spaces: *Spaces,
    windows: *Windows,
    displays: *const Displays,
    config: *const Config,
) void {
    const display_list = platform.getAllDisplays(allocator) orelse return;
    defer allocator.free(display_list);

    // First pass
    for (display_list) |did| {
        const sid = platform.getActiveSpaceForDisplay(did) orelse continue;
        const bounds = getBoundsForSpace(platform, displays, config, sid) orelse continue;

        spaces.applyLayout(sid, bounds, windows) catch |err| {
            log.warn("applyAllSpaceLayouts: failed for space {}: {}", .{ sid, err });
            continue;
        };
        log.info("applied layout to space {}", .{sid});
    }

    // Wait for macOS/apps to settle, then apply again
    std.Thread.sleep(200 * std.time.ns_per_ms);

    for (display_list) |did| {
        const sid = platform.getActiveSpaceForDisplay(did) orelse continue;
        const bounds = getBoundsForSpace(platform, displays, config, sid) orelse continue;
        spaces.applyLayout(sid, bounds, windows) catch {};
    }
}

/// Layout only currently visible spaces
pub fn layoutVisibleSpaces(
    allocator: std.mem.Allocator,
    platform: Platform,
    spaces: *Spaces,
    windows: *Windows,
    displays: *const Displays,
    config: *const Config,
) void {
    const display_list = platform.getAllDisplays(allocator) orelse return;
    defer allocator.free(display_list);

    for (display_list) |did| {
        const sid = platform.getActiveSpaceForDisplay(did) orelse continue;
        const bounds = getBoundsForSpace(platform, displays, config, sid) orelse continue;
        spaces.applyLayout(sid, bounds, windows) catch |err| {
            log.warn("layout failed for space {}: {}", .{ sid, err });
        };
    }

    // Second pass after delay for stubborn windows
    std.Thread.sleep(100 * std.time.ns_per_ms);
    for (display_list) |did| {
        const sid = platform.getActiveSpaceForDisplay(did) orelse continue;
        const bounds = getBoundsForSpace(platform, displays, config, sid) orelse continue;
        spaces.applyLayout(sid, bounds, windows) catch {};
    }
}

/// Warp mouse cursor to center of window (if not already inside)
pub fn warpMouseToWindow(platform: Platform, wid: Window.Id) void {
    const frame = platform.getWindowFrame(wid) orelse {
        log.debug("mouse warp: failed to get frame for wid={d}", .{wid});
        return;
    };

    // Check if cursor is already inside window
    const cursor = platform.getCursorPosition();
    if (cursor.x >= frame.x and cursor.x <= frame.x + frame.width and
        cursor.y >= frame.y and cursor.y <= frame.y + frame.height)
    {
        log.debug("mouse warp: cursor already inside wid={d}", .{wid});
        return;
    }

    // Warp to center
    const center = c.CGPoint{
        .x = frame.x + frame.width / 2,
        .y = frame.y + frame.height / 2,
    };

    _ = c.c.CGAssociateMouseAndMouseCursorPosition(0);
    _ = c.c.CGWarpMouseCursorPosition(center);
    _ = c.c.CGAssociateMouseAndMouseCursorPosition(1);
    log.debug("mouse warp: wid={d} to ({d:.0},{d:.0})", .{ wid, center.x, center.y });
}

/// Get current space ID from main display
pub fn getCurrentSpaceId(platform: Platform) ?u64 {
    const main_display = Displays.getMainDisplayId();
    return platform.getActiveSpaceForDisplay(main_display);
}

/// Get all space IDs across all displays
pub fn getAllSpaceIds(allocator: std.mem.Allocator, platform: Platform) ?[]u64 {
    const display_list = platform.getAllDisplays(allocator) orelse return null;
    defer allocator.free(display_list);

    var all_spaces: std.ArrayList(u64) = .empty;
    for (display_list) |did| {
        const space_list = platform.getDisplaySpaces(allocator, did) orelse continue;
        defer allocator.free(space_list);
        for (space_list) |sid| {
            all_spaces.append(allocator, sid) catch continue;
        }
    }

    if (all_spaces.items.len == 0) {
        all_spaces.deinit(allocator);
        return null;
    }
    return all_spaces.toOwnedSlice(allocator) catch null;
}

/// Get space ID from 1-based index
pub fn spaceIdFromIndex(allocator: std.mem.Allocator, platform: Platform, index: u64) ?u64 {
    if (index == 0) return null;
    const space_list = getAllSpaceIds(allocator, platform) orelse return null;
    defer allocator.free(space_list);
    if (index > space_list.len) return null;
    return space_list[index - 1];
}

// ============================================================================
// Tests
// ============================================================================

const Mock = @import("../platform/Mock.zig").Mock;

test "getBoundsForSpace returns display bounds" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    // Setup: one display with one space
    const display_id: Display.Id = 1;
    const space_id: Space.Id = 100;
    const display_frame = geometry.Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    try mock.addDisplay(display_id, .{ .frame = display_frame, .active_space_id = space_id });
    try mock.addSpace(space_id, .{ .display_id = display_id, .space_type = .user, .is_active = true });

    var displays = Displays.init(allocator);
    defer displays.deinit();

    var config = Config.initWithAllocator(allocator);
    defer config.deinit();

    const platform = mock.platform();
    const bounds = getBoundsForSpace(platform, &displays, &config, space_id);

    try std.testing.expect(bounds != null);
    try std.testing.expectEqual(@as(f64, 0), bounds.?.x);
    try std.testing.expectEqual(@as(f64, 0), bounds.?.y);
    try std.testing.expectEqual(@as(f64, 1920), bounds.?.width);
    try std.testing.expectEqual(@as(f64, 1080), bounds.?.height);
}

test "getBoundsForSpace applies external bar padding" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    const display_id: Display.Id = 1;
    const space_id: Space.Id = 100;
    const display_frame = geometry.Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    try mock.addDisplay(display_id, .{ .frame = display_frame, .active_space_id = space_id });
    try mock.addSpace(space_id, .{ .display_id = display_id, .space_type = .user, .is_active = true });

    var displays = Displays.init(allocator);
    defer displays.deinit();

    var config = Config.initWithAllocator(allocator);
    defer config.deinit();
    config.external_bar = .{ .position = .all, .top_padding = 30, .bottom_padding = 0 };

    const platform = mock.platform();
    const bounds = getBoundsForSpace(platform, &displays, &config, space_id);

    try std.testing.expect(bounds != null);
    try std.testing.expectEqual(@as(f64, 30), bounds.?.y);
    try std.testing.expectEqual(@as(f64, 1050), bounds.?.height);
}

test "getAllSpaceIds returns spaces from all displays" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    // Setup: two displays, each with 2 spaces
    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 100 });
    try mock.addDisplay(2, .{ .frame = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 200 });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addSpace(101, .{ .display_id = 1, .space_type = .user, .is_active = false });
    try mock.addSpace(200, .{ .display_id = 2, .space_type = .user, .is_active = true });
    try mock.addSpace(201, .{ .display_id = 2, .space_type = .user, .is_active = false });

    const platform = mock.platform();
    const spaces = getAllSpaceIds(allocator, platform);
    try std.testing.expect(spaces != null);
    defer allocator.free(spaces.?);

    try std.testing.expectEqual(@as(usize, 4), spaces.?.len);
}

test "spaceIdFromIndex returns correct space" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 100 });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addSpace(101, .{ .display_id = 1, .space_type = .user, .is_active = false });
    try mock.addSpace(102, .{ .display_id = 1, .space_type = .user, .is_active = false });

    const platform = mock.platform();

    // Note: HashMap iteration order isn't guaranteed, so we just check:
    // - Valid indices (1-3) return some space ID
    // - Invalid indices (0, 4) return null
    const s1 = spaceIdFromIndex(allocator, platform, 1);
    const s2 = spaceIdFromIndex(allocator, platform, 2);
    const s3 = spaceIdFromIndex(allocator, platform, 3);

    try std.testing.expect(s1 != null);
    try std.testing.expect(s2 != null);
    try std.testing.expect(s3 != null);
    try std.testing.expect(s1.? == 100 or s1.? == 101 or s1.? == 102);
    try std.testing.expect(s2.? == 100 or s2.? == 101 or s2.? == 102);
    try std.testing.expect(s3.? == 100 or s3.? == 101 or s3.? == 102);
    try std.testing.expect(s1.? != s2.? and s2.? != s3.? and s1.? != s3.?); // All different

    try std.testing.expectEqual(@as(?u64, null), spaceIdFromIndex(allocator, platform, 4));
    try std.testing.expectEqual(@as(?u64, null), spaceIdFromIndex(allocator, platform, 0));
}

test "applyLayoutToSpace creates view for space" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    // Setup: one display, one space (no windows to avoid ax_ref errors)
    const display_id: Display.Id = 1;
    const space_id: Space.Id = 100;
    const display_frame = geometry.Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    try mock.addDisplay(display_id, .{ .frame = display_frame, .active_space_id = space_id });
    try mock.addSpace(space_id, .{ .display_id = display_id, .space_type = .user, .is_active = true });

    var spaces = Spaces.init(allocator);
    defer spaces.deinit();

    var windows = Windows.init(allocator);
    defer windows.deinit();

    // Apply layout to empty space - should create view without errors
    const bounds = geometry.Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    applyLayoutToSpace(&spaces, &windows, space_id, bounds);

    // View should have been created
    try std.testing.expect(spaces.getView(space_id) != null);
}

test "layoutVisibleSpaces processes multiple displays" {
    const allocator = std.testing.allocator;

    var mock = Mock.init(allocator);
    defer mock.deinit();

    // Setup: two displays, each with active space (no windows to avoid ax_ref errors)
    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 100 });
    try mock.addDisplay(2, .{ .frame = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 200 });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });
    try mock.addSpace(200, .{ .display_id = 2, .space_type = .user, .is_active = true });

    var spaces = Spaces.init(allocator);
    defer spaces.deinit();

    var windows = Windows.init(allocator);
    defer windows.deinit();

    var displays = Displays.init(allocator);
    defer displays.deinit();

    var config = Config.initWithAllocator(allocator);
    defer config.deinit();

    const platform = mock.platform();

    // This should process both spaces without crashing
    // Note: layoutVisibleSpaces has sleeps, but with empty spaces it's fast
    layoutVisibleSpaces(allocator, platform, &spaces, &windows, &displays, &config);

    // Views should have been created for both spaces
    try std.testing.expect(spaces.getView(100) != null);
    try std.testing.expect(spaces.getView(200) != null);
}
