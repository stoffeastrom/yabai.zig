const std = @import("std");
const View = @import("View.zig");
const Window = @import("Window.zig");
const geometry = @import("geometry.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;

/// Layout engine - applies view layouts to windows
pub const Layout = @This();

/// Direction for window navigation/movement
pub const Direction = enum(u8) {
    north = 0,
    east = 1,
    south = 2,
    west = 3,

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .north => .south,
            .south => .north,
            .east => .west,
            .west => .east,
        };
    }

    pub fn axis(self: Direction) View.Split {
        return switch (self) {
            .north, .south => .horizontal,
            .east, .west => .vertical,
        };
    }
};

/// Grid placement specification (rows:cols:x:y:w:h)
pub const Grid = struct {
    rows: u32,
    cols: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn toRect(self: Grid, bounds: Rect) Rect {
        const cell_w = bounds.width / @as(f64, @floatFromInt(self.cols));
        const cell_h = bounds.height / @as(f64, @floatFromInt(self.rows));

        return .{
            .x = bounds.x + cell_w * @as(f64, @floatFromInt(self.x)),
            .y = bounds.y + cell_h * @as(f64, @floatFromInt(self.y)),
            .width = cell_w * @as(f64, @floatFromInt(self.w)),
            .height = cell_h * @as(f64, @floatFromInt(self.h)),
        };
    }

    pub fn parse(input: []const u8) ?Grid {
        var parts: [6]u32 = undefined;
        var i: usize = 0;
        var iter = std.mem.splitScalar(u8, input, ':');

        while (iter.next()) |part| {
            if (i >= 6) return null;
            parts[i] = std.fmt.parseInt(u32, part, 10) catch return null;
            i += 1;
        }

        if (i != 6) return null;
        if (parts[0] == 0 or parts[1] == 0) return null;
        if (parts[4] == 0 or parts[5] == 0) return null;

        return .{
            .rows = parts[0],
            .cols = parts[1],
            .x = parts[2],
            .y = parts[3],
            .w = parts[4],
            .h = parts[5],
        };
    }
};

/// Find window in direction from source
/// Find window in direction from source window.
/// NOTE: This is now handled directly in CommandHandler using actual window frames.
/// Keeping this stub for potential future use with BSP node-based navigation.
pub fn findWindowInDirection(
    view: *View,
    source_wid: Window.Id,
    direction: Direction,
) ?Window.Id {
    _ = view;
    _ = source_wid;
    _ = direction;
    // Directional navigation now uses frame-based lookup in CommandHandler
    return null;
}

/// Find node in direction from source node
pub fn findNodeInDirection(
    view: *View,
    source: *View.Node,
    direction: Direction,
) ?*View.Node {
    const source_max = Point{
        .x = source.area.x + source.area.width - 1,
        .y = source.area.y + source.area.height - 1,
    };

    var best_node: ?*View.Node = null;
    var best_distance: f64 = std.math.floatMax(f64);

    // Iterate ALL leaf nodes starting from root
    var node: ?*View.Node = view.root.findFirstLeaf();
    while (node) |n| {
        if (n != source) {
            const target_max = Point{
                .x = n.area.x + n.area.width - 1,
                .y = n.area.y + n.area.height - 1,
            };

            if (isInDirection(&source.area, source_max, &n.area, target_max, direction)) {
                const dist = distanceInDirection(&source.area, source_max, &n.area, target_max, direction);
                if (dist < best_distance) {
                    best_distance = dist;
                    best_node = n;
                }
            }
        }
        node = n.findNextLeaf();
    }

    return best_node;
}

fn isInDirection(r1: *const Rect, r1_max: Point, r2: *const Rect, r2_max: Point, direction: Direction) bool {
    switch (direction) {
        .north => if (r1_max.y <= r2.y) return false,
        .east => if (r2_max.x <= r1.x) return false,
        .south => if (r2_max.y <= r1.y) return false,
        .west => if (r1_max.x <= r2.x) return false,
    }

    // Check overlap on perpendicular axis
    return switch (direction) {
        .north, .south => (r2_max.x > r1.x and r2_max.x <= r1_max.x) or
            (r2.x < r1.x and r2_max.x > r1_max.x) or
            (r2.x >= r1.x and r2.x < r1_max.x),
        .east, .west => (r2_max.y > r1.y and r2_max.y <= r1_max.y) or
            (r2.y < r1.y and r2_max.y > r1_max.y) or
            (r2.y >= r1.y and r2.y < r1_max.y),
    };
}

fn distanceInDirection(r1: *const Rect, r1_max: Point, r2: *const Rect, r2_max: Point, direction: Direction) f64 {
    return switch (direction) {
        .north => if (r2_max.y > r1.y) r2_max.y - r1.y else r1.y - r2_max.y,
        .east => if (r2.x < r1_max.x) r1_max.x - r2.x else r2.x - r1_max.x,
        .south => if (r2.y < r1_max.y) r1_max.y - r2.y else r2.y - r1_max.y,
        .west => if (r2_max.x > r1.x) r2_max.x - r1.x else r1.x - r2_max.x,
    };
}

/// Swap windows between two nodes
/// NOTE: In the new pure-BSP model, nodes don't store window IDs.
/// Swap is done by reordering windows in the window list before layout.
pub fn swapWindows(node_a: *View.Node, node_b: *View.Node) void {
    // In the new model, this is a no-op at the View level.
    // Window order is managed externally.
    _ = node_a;
    _ = node_b;
}

/// Warp a window to another node's position
/// NOTE: In the new pure-BSP model, this is done by reordering the window list.
pub fn warpWindow(view: *View, source_wid: Window.Id, target_wid: Window.Id) !void {
    _ = view;
    _ = source_wid;
    _ = target_wid;
    // No-op - window ordering is managed externally
}

/// Find the fence (parent split) in a given direction
pub fn findFence(node: *View.Node, direction: Direction) ?*View.Node {
    var current = node.parent;
    while (current) |parent| {
        const in_dir = switch (direction) {
            .north => parent.split == .horizontal and parent.area.y < node.area.y,
            .south => parent.split == .horizontal and (parent.area.y + parent.area.height) > (node.area.y + node.area.height),
            .west => parent.split == .vertical and parent.area.x < node.area.x,
            .east => parent.split == .vertical and (parent.area.x + parent.area.width) > (node.area.x + node.area.width),
        };
        if (in_dir) return parent;
        current = parent.parent;
    }
    return null;
}

/// Adjust the ratio of a fence in a given direction
pub fn adjustRatio(node: *View.Node, direction: Direction, delta: f32) bool {
    const fence = findFence(node, direction) orelse return false;

    const new_ratio = fence.ratio + delta;
    if (new_ratio < 0.1 or new_ratio > 0.9) return false;

    fence.ratio = new_ratio;
    return true;
}

/// Equalize all ratios in the tree (along specified axis or both)
pub fn equalize(view: *View, axis: ?View.Split) void {
    equalizeNode(view.root, axis, view.split_ratio);
}

fn equalizeNode(node: *View.Node, axis: ?View.Split, ratio: f32) void {
    if (node.left) |left| equalizeNode(left, axis, ratio);
    if (node.right) |right| equalizeNode(right, axis, ratio);

    if (axis) |a| {
        if (node.split == a) node.ratio = ratio;
    } else {
        if (node.split != .none and node.split != .auto) {
            node.ratio = ratio;
        }
    }
}

/// Balance tree so windows have equal areas
pub fn balance(view: *View, axis: ?View.Split) void {
    _ = balanceNode(view.root, axis);
}

const BalanceCount = struct { y: u32, x: u32 };

fn balanceNode(node: *View.Node, axis: ?View.Split) BalanceCount {
    if (node.isLeaf()) {
        return .{
            .y = if (node.parent) |p| @intFromBool(p.split == .vertical) else 0,
            .x = if (node.parent) |p| @intFromBool(p.split == .horizontal) else 0,
        };
    }

    const left_count = balanceNode(node.left.?, axis);
    const right_count = balanceNode(node.right.?, axis);
    var total = BalanceCount{
        .y = left_count.y + right_count.y,
        .x = left_count.x + right_count.x,
    };

    if (axis == null or axis == .vertical) {
        if (node.split == .vertical and total.y > 0) {
            node.ratio = @as(f32, @floatFromInt(left_count.y)) / @as(f32, @floatFromInt(total.y));
            total.y -= 1;
        }
    }

    if (axis == null or axis == .horizontal) {
        if (node.split == .horizontal and total.x > 0) {
            node.ratio = @as(f32, @floatFromInt(left_count.x)) / @as(f32, @floatFromInt(total.x));
            total.x -= 1;
        }
    }

    if (node.parent) |p| {
        total.y += @intFromBool(p.split == .vertical);
        total.x += @intFromBool(p.split == .horizontal);
    }

    return total;
}

// ============================================================================
// Tests
// ============================================================================

test "Grid.parse" {
    const grid = Grid.parse("2:3:0:0:1:1").?;
    try std.testing.expectEqual(@as(u32, 2), grid.rows);
    try std.testing.expectEqual(@as(u32, 3), grid.cols);
    try std.testing.expectEqual(@as(u32, 0), grid.x);
    try std.testing.expectEqual(@as(u32, 0), grid.y);
    try std.testing.expectEqual(@as(u32, 1), grid.w);
    try std.testing.expectEqual(@as(u32, 1), grid.h);
}

test "Grid.parse invalid" {
    try std.testing.expect(Grid.parse("2:3:0:0:1") == null);
    try std.testing.expect(Grid.parse("0:3:0:0:1:1") == null);
    try std.testing.expect(Grid.parse("2:3:0:0:0:1") == null);
}

test "Grid.toRect" {
    const grid = Grid{ .rows = 2, .cols = 2, .x = 1, .y = 0, .w = 1, .h = 2 };
    const bounds = Rect.init(0, 0, 1000, 800);
    const rect = grid.toRect(bounds);

    try std.testing.expectEqual(@as(f64, 500), rect.x);
    try std.testing.expectEqual(@as(f64, 0), rect.y);
    try std.testing.expectEqual(@as(f64, 500), rect.width);
    try std.testing.expectEqual(@as(f64, 800), rect.height);
}

test "Direction.opposite" {
    try std.testing.expectEqual(Direction.south, Direction.north.opposite());
    try std.testing.expectEqual(Direction.north, Direction.south.opposite());
    try std.testing.expectEqual(Direction.west, Direction.east.opposite());
    try std.testing.expectEqual(Direction.east, Direction.west.opposite());
}

test "Direction.axis" {
    try std.testing.expectEqual(View.Split.horizontal, Direction.north.axis());
    try std.testing.expectEqual(View.Split.horizontal, Direction.south.axis());
    try std.testing.expectEqual(View.Split.vertical, Direction.east.axis());
    try std.testing.expectEqual(View.Split.vertical, Direction.west.axis());
}

// Tests for swapWindows, equalize, findWindowInDirection, findFence, adjustRatio,
// warpWindow, and balance are currently disabled because View no longer tracks
// window IDs in nodes. These operations need reimplementing for the new model
// where window ordering is managed externally.
