//! Visual feedback overlay for window insertion during drag operations.
//! Creates a translucent colored rectangle to show where a window will be tiled.

const std = @import("std");
const c = @import("../platform/c.zig");
const sl_mod = @import("../platform/skylight.zig");
const geometry = @import("../core/geometry.zig");

const log = std.log.scoped(.feedback);

pub const InsertFeedback = @This();

/// Window ID of the feedback overlay (0 = not shown)
window_id: u32 = 0,
/// SkyLight connection for window operations
connection: c_int = 0,
/// Cached SkyLight instance
skylight: ?*const sl_mod.SkyLight = null,

/// Initialize feedback system
pub fn init(connection: c_int) InsertFeedback {
    return .{
        .connection = connection,
        .skylight = sl_mod.get() catch null,
    };
}

/// Show feedback rectangle at specified frame with color
pub fn show(self: *InsertFeedback, frame: geometry.Rect, color: u32) void {
    const sl = self.skylight orelse return;

    log.debug("feedback: show start, connection={}", .{self.connection});

    // Destroy existing window if any
    if (self.window_id != 0) {
        _ = sl.SLSReleaseWindow(self.connection, self.window_id);
        self.window_id = 0;
    }

    // Create region for window shape (same pattern as original yabai)
    const region_rect = c.CGRect{
        .origin = .{ .x = frame.x, .y = frame.y },
        .size = .{ .width = @floatCast(frame.width), .height = @floatCast(frame.height) },
    };

    log.debug("feedback: calling CGSNewRegionWithRect", .{});
    var frame_region: c.CFTypeRef = null;
    const region_err = sl.CGSNewRegionWithRect(&region_rect, &frame_region);
    if (region_err != 0 or frame_region == null) {
        log.warn("failed to create region for feedback window: err={}", .{region_err});
        return;
    }
    defer c.c.CFRelease(frame_region);
    log.debug("feedback: frame region created", .{});

    // Create empty region for opaque shape (zero-sized rect = empty region)
    const zero_rect = c.CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    };
    var empty_region: c.CFTypeRef = null;
    const empty_err = sl.CGSNewRegionWithRect(&zero_rect, &empty_region);
    if (empty_err != 0 or empty_region == null) {
        log.warn("failed to create empty region: err={}", .{empty_err});
        return;
    }
    defer c.c.CFRelease(empty_region);
    log.debug("feedback: empty region created", .{});

    // Create window using SLSNewWindowWithOpaqueShapeAndContext (same as original yabai)
    var wid: u32 = 0;
    var tags: u64 = (1 << 1) | (1 << 9); // Same tags as yabai feedback window

    log.debug("feedback: calling SLSNewWindowWithOpaqueShapeAndContext", .{});
    const err = sl.SLSNewWindowWithOpaqueShapeAndContext(
        self.connection,
        2, // kCGBackingStoreBuffered
        frame_region,
        empty_region,
        13, // window level
        &tags,
        0, // x offset
        0, // y offset
        64, // options
        &wid,
        null, // context
    );

    if (err != 0 or wid == 0) {
        log.warn("failed to create feedback window: err={}", .{err});
        return;
    }
    log.debug("feedback: window created wid={}", .{wid});

    self.window_id = wid;

    // Set window properties
    _ = sl.SLSSetWindowOpacity(self.connection, wid, false); // Allow transparency

    // Extract ARGB components
    const alpha: f32 = @as(f32, @floatFromInt((color >> 24) & 0xFF)) / 255.0;
    _ = sl.SLSSetWindowAlpha(self.connection, wid, alpha);

    // Set window level high so it appears above other windows
    _ = sl.SLSSetWindowLevel(self.connection, wid, 25);

    // Order the window to be visible
    _ = sl.SLSOrderWindow(self.connection, wid, sl_mod.WindowOrder.above, 0);

    // Draw the colored rectangle
    self.draw(frame, color);

    log.debug("feedback: shown wid={} at ({d:.0},{d:.0}) {d:.0}x{d:.0}", .{
        wid, frame.x, frame.y, frame.width, frame.height,
    });
}

/// Update feedback position and size
pub fn update(self: *InsertFeedback, frame: geometry.Rect, color: u32) void {
    if (self.window_id == 0) {
        // Not visible, create new
        self.show(frame, color);
        return;
    }

    const sl = self.skylight orelse return;

    // Move window to new position
    var point = c.CGPoint{
        .x = @floatCast(frame.x),
        .y = @floatCast(frame.y),
    };
    _ = sl.SLSMoveWindow(self.connection, self.window_id, &point);

    // Update shape if size changed
    const path = c.c.CGPathCreateWithRect(.{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatCast(frame.width), .height = @floatCast(frame.height) },
    }, null);
    if (path != null) {
        defer c.c.CGPathRelease(path);
        _ = sl.SLSSetWindowShape(
            self.connection,
            self.window_id,
            0,
            0,
            @ptrCast(path),
        );
    }

    // Redraw with color
    self.draw(frame, color);
}

/// Draw the feedback rectangle
fn draw(self: *InsertFeedback, frame: geometry.Rect, color: u32) void {
    _ = self;

    // Create a CGContext for the window
    const color_space = c.c.CGColorSpaceCreateDeviceRGB();
    if (color_space == null) return;
    defer c.c.CGColorSpaceRelease(color_space);

    const width: usize = @intFromFloat(frame.width);
    const height: usize = @intFromFloat(frame.height);
    if (width == 0 or height == 0) return;

    const context = c.c.CGBitmapContextCreate(
        null, // let CG manage memory
        width,
        height,
        8, // bits per component
        width * 4, // bytes per row
        color_space,
        c.c.kCGImageAlphaPremultipliedFirst | c.c.kCGBitmapByteOrder32Little,
    );
    if (context == null) return;
    defer c.c.CGContextRelease(context);

    // Extract ARGB components and convert to 0-1 range
    const a: c.c.CGFloat = @as(c.c.CGFloat, @floatFromInt((color >> 24) & 0xFF)) / 255.0;
    const r: c.c.CGFloat = @as(c.c.CGFloat, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g: c.c.CGFloat = @as(c.c.CGFloat, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b: c.c.CGFloat = @as(c.c.CGFloat, @floatFromInt(color & 0xFF)) / 255.0;

    // Fill with color
    c.c.CGContextSetRGBFillColor(context, r, g, b, a);
    c.c.CGContextFillRect(context, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatCast(frame.width), .height = @floatCast(frame.height) },
    });

    // Note: For SkyLight windows, we'd need SLSSetWindowContextBuffer or similar
    // to actually update the window content. For now, the window itself provides
    // visual feedback through its frame/alpha.
}

/// Hide and destroy the feedback window
pub fn hide(self: *InsertFeedback) void {
    if (self.window_id == 0) return;

    const sl = self.skylight orelse return;
    _ = sl.SLSReleaseWindow(self.connection, self.window_id);
    self.window_id = 0;

    log.debug("feedback: hidden", .{});
}

/// Check if feedback is currently visible
pub fn isVisible(self: *const InsertFeedback) bool {
    return self.window_id != 0;
}

/// Deinitialize - ensure window is destroyed
pub fn deinit(self: *InsertFeedback) void {
    self.hide();
}

// ============================================================================
// Tests
// ============================================================================

test "InsertFeedback init" {
    var feedback = InsertFeedback.init(0);
    defer feedback.deinit();

    try std.testing.expectEqual(@as(u32, 0), feedback.window_id);
    try std.testing.expect(!feedback.isVisible());
}
