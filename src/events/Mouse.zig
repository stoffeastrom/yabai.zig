//! Mouse handling for window move/resize operations.
//! Intercepts mouse events when modifier keys are held.

const std = @import("std");
const c = @import("../platform/c.zig");
const geometry = @import("../core/geometry.zig");
const Window = @import("../core/Window.zig");
const View = @import("../core/View.zig");
const InsertFeedback = @import("InsertFeedback.zig").InsertFeedback;

const Point = geometry.Point;
const Rect = geometry.Rect;

pub const Mouse = @This();

/// Mouse action modes
pub const Mode = enum {
    none,
    move,
    resize,
    swap,
    stack,
};

/// Keyboard modifier for mouse actions
pub const Modifier = enum(u8) {
    none = 0x01,
    alt = 0x02,
    shift = 0x04,
    cmd = 0x08,
    ctrl = 0x10,
    fn_key = 0x20,

    pub fn fromCGFlags(flags: u64) Modifier {
        if ((flags & 0x80000) != 0) return .fn_key;
        if ((flags & 0x100000) != 0) return .alt;
        if ((flags & 0x20000) != 0) return .shift;
        if ((flags & 0x100000) != 0) return .cmd;
        if ((flags & 0x40000) != 0) return .ctrl;
        return .none;
    }
};

/// Drop action when releasing a dragged window
pub const DropAction = enum {
    none,
    stack,
    swap,
    warp_top,
    warp_right,
    warp_bottom,
    warp_left,
};

/// Information about window changes during drag
pub const WindowInfo = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    dw: f32 = 0,
    dh: f32 = 0,
    changed_x: bool = false,
    changed_y: bool = false,
    changed_w: bool = false,
    changed_h: bool = false,

    pub fn changedPosition(self: WindowInfo) bool {
        return self.changed_x or self.changed_y;
    }

    pub fn changedSize(self: WindowInfo) bool {
        return self.changed_w or self.changed_h;
    }

    pub fn populate(original: Rect, current: Rect) WindowInfo {
        const dx = @as(f32, @floatCast(current.x - original.x));
        const dy = @as(f32, @floatCast(current.y - original.y));
        const dw = @as(f32, @floatCast(current.width - original.width));
        const dh = @as(f32, @floatCast(current.height - original.height));

        return .{
            .dx = dx,
            .dy = dy,
            .dw = dw,
            .dh = dh,
            .changed_x = dx != 0,
            .changed_y = dy != 0,
            .changed_w = dw != 0,
            .changed_h = dh != 0,
        };
    }
};

/// Mouse state for tracking drag operations
pub const State = struct {
    /// Required modifier to activate mouse actions
    modifier: Modifier = .fn_key,
    /// Action for primary mouse button
    action1: Mode = .move,
    /// Action for secondary mouse button
    action2: Mode = .resize,
    /// Drop action (swap vs stack)
    drop_action: Mode = .swap,
    /// Current active action
    current_action: Mode = .none,
    /// Whether we consumed the initial click
    consume_click: bool = false,
    /// Whether drag was detected
    drag_detected: bool = false,
    /// Mouse down location
    down_location: Point = .{},
    /// Window being dragged
    window_id: ?Window.Id = null,
    /// Original window frame
    original_frame: Rect = .{},
    /// Last FFM window
    ffm_window_id: ?Window.Id = null,
    /// Resize direction
    direction: u8 = 0,
    /// Target window for drop (the window under cursor during drag)
    target_window_id: ?Window.Id = null,
    /// Current drop action determined during drag
    current_drop_action: DropAction = .none,
    /// Visual feedback overlay for insertion point
    feedback: ?InsertFeedback = null,
    /// Feedback color (ARGB)
    feedback_color: u32 = 0xffd75f5f,

    pub fn init() State {
        return .{};
    }

    /// Initialize with SkyLight connection for feedback windows
    pub fn initWithConnection(connection: c_int) State {
        return .{
            .feedback = InsertFeedback.init(connection),
        };
    }

    pub fn reset(self: *State) void {
        // Hide feedback before reset
        if (self.feedback) |*fb| {
            fb.hide();
        }
        self.current_action = .none;
        self.consume_click = false;
        self.drag_detected = false;
        self.window_id = null;
        self.target_window_id = null;
        self.current_drop_action = .none;
    }

    /// Deinitialize feedback resources
    pub fn deinit(self: *State) void {
        if (self.feedback) |*fb| {
            fb.deinit();
        }
    }

    /// Update feedback display based on current drag state
    pub fn updateFeedback(self: *State, target_frame: ?Rect) void {
        const fb = &(self.feedback orelse return);

        if (self.current_drop_action == .none or target_frame == null) {
            fb.hide();
            return;
        }

        // Calculate feedback rect based on drop action
        const frame = target_frame.?;
        const feedback_frame: Rect = switch (self.current_drop_action) {
            .stack, .swap => frame, // Full frame for center drop
            .warp_left => .{
                .x = frame.x,
                .y = frame.y,
                .width = frame.width / 2,
                .height = frame.height,
            },
            .warp_right => .{
                .x = frame.x + frame.width / 2,
                .y = frame.y,
                .width = frame.width / 2,
                .height = frame.height,
            },
            .warp_top => .{
                .x = frame.x,
                .y = frame.y,
                .width = frame.width,
                .height = frame.height / 2,
            },
            .warp_bottom => .{
                .x = frame.x,
                .y = frame.y + frame.height / 2,
                .width = frame.width,
                .height = frame.height / 2,
            },
            .none => {
                fb.hide();
                return;
            },
        };

        fb.update(feedback_frame, self.feedback_color);
    }

    /// Determine the resize direction based on click position within window
    pub fn determineResizeDirection(self: *State, click: Point, frame: Rect) void {
        const mid_x = frame.x + frame.width / 2;
        const mid_y = frame.y + frame.height / 2;

        self.direction = 0;
        if (click.x < mid_x) self.direction |= HANDLE_LEFT;
        if (click.x > mid_x) self.direction |= HANDLE_RIGHT;
        if (click.y < mid_y) self.direction |= HANDLE_TOP;
        if (click.y > mid_y) self.direction |= HANDLE_BOTTOM;
    }
};

// Direction flags for resize
pub const HANDLE_LEFT: u8 = 0x01;
pub const HANDLE_RIGHT: u8 = 0x02;
pub const HANDLE_TOP: u8 = 0x04;
pub const HANDLE_BOTTOM: u8 = 0x08;

/// Determine drop action based on where mouse is released over target window
pub fn determineDropAction(state: *const State, target_frame: Rect, point: Point) DropAction {
    // Relative position within target
    const rel_x = point.x - target_frame.x;
    const rel_y = point.y - target_frame.y;

    // Center zone (25% padding on each side = 50% center)
    const center = Rect{
        .x = target_frame.width * 0.25,
        .y = target_frame.height * 0.25,
        .width = target_frame.width * 0.5,
        .height = target_frame.height * 0.5,
    };

    // Check if in center zone
    if (rel_x >= center.x and rel_x <= center.x + center.width and
        rel_y >= center.y and rel_y <= center.y + center.height)
    {
        return if (state.drop_action == .stack) .stack else .swap;
    }

    // Determine which edge/corner
    const norm_x = rel_x / target_frame.width;
    const norm_y = rel_y / target_frame.height;

    // Use triangular regions for edges
    if (norm_y < norm_x and norm_y < (1 - norm_x)) return .warp_top;
    if (norm_x > norm_y and norm_x > (1 - norm_y)) return .warp_right;
    if (norm_y > norm_x and norm_y > (1 - norm_x)) return .warp_bottom;
    if (norm_x < norm_y and norm_x < (1 - norm_y)) return .warp_left;

    return .none;
}

/// Check if point is inside a triangle (for edge detection)
fn pointInTriangle(p: Point, v0: Point, v1: Point, v2: Point) bool {
    const d00 = dot(v0, v1, v0, v1);
    const d01 = dot(v0, v1, v0, v2);
    const d02 = dot(v0, v1, v0, p);
    const d11 = dot(v0, v2, v0, v2);
    const d12 = dot(v0, v2, v0, p);

    const denom = d00 * d11 - d01 * d01;
    if (denom == 0) return false;

    const inv_denom = 1.0 / denom;
    const u = (d11 * d02 - d01 * d12) * inv_denom;
    const v = (d00 * d12 - d01 * d02) * inv_denom;

    return u >= 0 and v >= 0 and (u + v) <= 1;
}

fn dot(p1: Point, p2: Point, p3: Point, p4: Point) f64 {
    return (p2.x - p1.x) * (p4.x - p3.x) + (p2.y - p1.y) * (p4.y - p3.y);
}

// Tests
test "WindowInfo.populate" {
    const original = Rect{ .x = 100, .y = 100, .width = 400, .height = 300 };
    const current = Rect{ .x = 150, .y = 100, .width = 450, .height = 300 };
    const info = WindowInfo.populate(original, current);

    try std.testing.expectEqual(@as(f32, 50), info.dx);
    try std.testing.expectEqual(@as(f32, 0), info.dy);
    try std.testing.expectEqual(@as(f32, 50), info.dw);
    try std.testing.expect(info.changed_x);
    try std.testing.expect(!info.changed_y);
    try std.testing.expect(info.changedPosition());
    try std.testing.expect(info.changedSize());
}

test "State.determineResizeDirection" {
    var state = State.init();
    const frame = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };

    // Top-left corner
    state.determineResizeDirection(.{ .x = 10, .y = 10 }, frame);
    try std.testing.expect((state.direction & HANDLE_LEFT) != 0);
    try std.testing.expect((state.direction & HANDLE_TOP) != 0);

    // Bottom-right corner
    state.determineResizeDirection(.{ .x = 90, .y = 90 }, frame);
    try std.testing.expect((state.direction & HANDLE_RIGHT) != 0);
    try std.testing.expect((state.direction & HANDLE_BOTTOM) != 0);
}

test "determineDropAction center" {
    const state = State.init();
    const frame = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };

    // Center should be swap
    const action = determineDropAction(&state, frame, .{ .x = 50, .y = 50 });
    try std.testing.expectEqual(DropAction.swap, action);
}

test "determineDropAction edges" {
    const state = State.init();
    const frame = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };

    // Top edge
    try std.testing.expectEqual(DropAction.warp_top, determineDropAction(&state, frame, .{ .x = 50, .y = 5 }));
    // Right edge
    try std.testing.expectEqual(DropAction.warp_right, determineDropAction(&state, frame, .{ .x = 95, .y = 50 }));
    // Bottom edge
    try std.testing.expectEqual(DropAction.warp_bottom, determineDropAction(&state, frame, .{ .x = 50, .y = 95 }));
    // Left edge
    try std.testing.expectEqual(DropAction.warp_left, determineDropAction(&state, frame, .{ .x = 5, .y = 50 }));
}
