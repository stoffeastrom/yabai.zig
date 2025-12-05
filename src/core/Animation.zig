const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Point = geometry.Point;

/// Easing functions for smooth window animations
pub const Easing = enum {
    ease_in_sine,
    ease_out_sine,
    ease_in_out_sine,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_in_quart,
    ease_out_quart,
    ease_in_out_quart,
    ease_in_quint,
    ease_out_quint,
    ease_in_out_quint,
    ease_in_expo,
    ease_out_expo,
    ease_in_out_expo,
    ease_in_circ,
    ease_out_circ,
    ease_in_out_circ,

    /// Apply easing function to normalized time t (0.0 to 1.0)
    pub fn apply(self: Easing, t: f64) f64 {
        return switch (self) {
            .ease_in_sine => 1.0 - @cos((t * std.math.pi) / 2.0),
            .ease_out_sine => @sin((t * std.math.pi) / 2.0),
            .ease_in_out_sine => -(@cos(std.math.pi * t) - 1.0) / 2.0,
            .ease_in_quad => t * t,
            .ease_out_quad => 1.0 - (1.0 - t) * (1.0 - t),
            .ease_in_out_quad => if (t < 0.5) 2.0 * t * t else 1.0 - std.math.pow(f64, -2.0 * t + 2.0, 2.0) / 2.0,
            .ease_in_cubic => t * t * t,
            .ease_out_cubic => 1.0 - std.math.pow(f64, 1.0 - t, 3.0),
            .ease_in_out_cubic => if (t < 0.5) 4.0 * t * t * t else 1.0 - std.math.pow(f64, -2.0 * t + 2.0, 3.0) / 2.0,
            .ease_in_quart => t * t * t * t,
            .ease_out_quart => 1.0 - std.math.pow(f64, 1.0 - t, 4.0),
            .ease_in_out_quart => if (t < 0.5) 8.0 * t * t * t * t else 1.0 - std.math.pow(f64, -2.0 * t + 2.0, 4.0) / 2.0,
            .ease_in_quint => t * t * t * t * t,
            .ease_out_quint => 1.0 - std.math.pow(f64, 1.0 - t, 5.0),
            .ease_in_out_quint => if (t < 0.5) 16.0 * t * t * t * t * t else 1.0 - std.math.pow(f64, -2.0 * t + 2.0, 5.0) / 2.0,
            .ease_in_expo => if (t == 0.0) 0.0 else std.math.pow(f64, 2.0, 10.0 * t - 10.0),
            .ease_out_expo => if (t == 1.0) 1.0 else 1.0 - std.math.pow(f64, 2.0, -10.0 * t),
            .ease_in_out_expo => if (t == 0.0) 0.0 else if (t == 1.0) 1.0 else if (t < 0.5) std.math.pow(f64, 2.0, 20.0 * t - 10.0) / 2.0 else (2.0 - std.math.pow(f64, 2.0, -20.0 * t + 10.0)) / 2.0,
            .ease_in_circ => 1.0 - @sqrt(1.0 - std.math.pow(f64, t, 2.0)),
            .ease_out_circ => @sqrt(1.0 - std.math.pow(f64, t - 1.0, 2.0)),
            .ease_in_out_circ => if (t < 0.5) (1.0 - @sqrt(1.0 - std.math.pow(f64, 2.0 * t, 2.0))) / 2.0 else (@sqrt(1.0 - std.math.pow(f64, -2.0 * t + 2.0, 2.0)) + 1.0) / 2.0,
        };
    }

    pub fn fromString(str: []const u8) ?Easing {
        return std.meta.stringToEnum(Easing, str);
    }
};

/// Linear interpolation
pub fn lerp(a: f64, t: f64, b: f64) f64 {
    return ((1.0 - t) * a) + (t * b);
}

/// Interpolate a rectangle
pub fn lerpRect(from: Rect, t: f64, to: Rect) Rect {
    return .{
        .x = lerp(from.x, t, to.x),
        .y = lerp(from.y, t, to.y),
        .width = lerp(from.width, t, to.width),
        .height = lerp(from.height, t, to.height),
    };
}

/// Window proxy for animation (screenshot during transition)
pub const WindowProxy = struct {
    id: u32 = 0,
    level: i32 = 0,
    sub_level: i32 = 0,
    frame: Rect = .{},
    // Current interpolated position
    tx: f64 = 0,
    ty: f64 = 0,
    tw: f64 = 0,
    th: f64 = 0,
};

/// Single window animation state
pub const WindowAnimation = struct {
    window_id: u32,
    connection: i32,
    // Target position
    target: Rect,
    // Proxy window for smooth animation
    proxy: WindowProxy = .{},
    // Skip this animation (window destroyed during animation)
    skip: bool = false,

    pub fn init(window_id: u32, connection: i32, target: Rect) WindowAnimation {
        return .{
            .window_id = window_id,
            .connection = connection,
            .target = target,
        };
    }

    /// Update animation for current time
    pub fn update(self: *WindowAnimation, eased_t: f64) void {
        if (self.skip) return;

        self.proxy.tx = lerp(self.proxy.frame.x, eased_t, self.target.x);
        self.proxy.ty = lerp(self.proxy.frame.y, eased_t, self.target.y);
        self.proxy.tw = lerp(self.proxy.frame.width, eased_t, self.target.width);
        self.proxy.th = lerp(self.proxy.frame.height, eased_t, self.target.height);
    }

    /// Check if animation reached target
    pub fn isComplete(self: *const WindowAnimation) bool {
        const epsilon = 0.5;
        return @abs(self.proxy.tx - self.target.x) < epsilon and
            @abs(self.proxy.ty - self.target.y) < epsilon and
            @abs(self.proxy.tw - self.target.width) < epsilon and
            @abs(self.proxy.th - self.target.height) < epsilon;
    }
};

/// Animation context managing multiple concurrent window animations
pub const Context = struct {
    connection: i32,
    easing: Easing,
    duration: f64, // seconds
    start_time: u64 = 0,
    animations: std.ArrayList(WindowAnimation) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, connection: i32, easing: Easing, duration: f64) Context {
        return .{
            .allocator = allocator,
            .connection = connection,
            .easing = easing,
            .duration = duration,
        };
    }

    pub fn deinit(self: *Context) void {
        self.animations.deinit(self.allocator);
    }

    /// Add a window to animate
    pub fn addWindow(self: *Context, window_id: u32, target: Rect) !void {
        try self.animations.append(self.allocator, WindowAnimation.init(window_id, self.connection, target));
    }

    /// Update all animations for current time
    pub fn update(self: *Context, current_time: u64, clock_frequency: u64) bool {
        if (self.start_time == 0) self.start_time = current_time;

        const elapsed = current_time - self.start_time;
        const t_raw: f64 = @as(f64, @floatFromInt(elapsed)) / (@as(f64, @floatFromInt(clock_frequency)) * self.duration);
        const t = @min(t_raw, 1.0);
        const eased_t = self.easing.apply(t);

        var all_complete = true;
        for (self.animations.items) |*anim| {
            anim.update(eased_t);
            if (!anim.skip and !anim.isComplete()) {
                all_complete = false;
            }
        }

        return t >= 1.0 or all_complete;
    }

    /// Mark a window animation as skipped (e.g., window was destroyed)
    pub fn skipWindow(self: *Context, window_id: u32) void {
        for (self.animations.items) |*anim| {
            if (anim.window_id == window_id) {
                anim.skip = true;
                break;
            }
        }
    }

    pub fn count(self: *const Context) usize {
        return self.animations.items.len;
    }

    pub fn activeCount(self: *const Context) usize {
        var n: usize = 0;
        for (self.animations.items) |anim| {
            if (!anim.skip) n += 1;
        }
        return n;
    }
};

// Tests
test "Easing.apply bounds" {
    const easings = std.enums.values(Easing);
    for (easings) |easing| {
        // t=0 should return ~0
        const at_zero = easing.apply(0.0);
        try std.testing.expect(at_zero >= -0.001 and at_zero <= 0.001);

        // t=1 should return ~1
        const at_one = easing.apply(1.0);
        try std.testing.expect(at_one >= 0.999 and at_one <= 1.001);

        // t=0.5 should be in range
        const at_half = easing.apply(0.5);
        try std.testing.expect(at_half >= 0.0 and at_half <= 1.0);
    }
}

test "lerp" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), lerp(0.0, 0.0, 100.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), lerp(0.0, 0.5, 100.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), lerp(0.0, 1.0, 100.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), lerp(50.0, 0.5, 100.0), 0.001);
}

test "lerpRect" {
    const from = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const to = Rect{ .x = 100, .y = 200, .width = 200, .height = 300 };
    const mid = lerpRect(from, 0.5, to);

    try std.testing.expectApproxEqAbs(@as(f64, 50.0), mid.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), mid.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), mid.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), mid.height, 0.001);
}

test "WindowAnimation.update" {
    var anim = WindowAnimation.init(1, 0, .{ .x = 100, .y = 100, .width = 200, .height = 200 });
    anim.proxy.frame = .{ .x = 0, .y = 0, .width = 100, .height = 100 };

    anim.update(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), anim.proxy.tx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), anim.proxy.ty, 0.001);
}

test "Context basic" {
    var ctx = Context.init(std.testing.allocator, 0, .ease_out_circ, 0.2);
    defer ctx.deinit();

    try ctx.addWindow(1, .{ .x = 100, .y = 100, .width = 200, .height = 200 });
    try ctx.addWindow(2, .{ .x = 300, .y = 100, .width = 200, .height = 200 });

    try std.testing.expectEqual(@as(usize, 2), ctx.count());

    ctx.skipWindow(1);
    try std.testing.expectEqual(@as(usize, 1), ctx.activeCount());
}
