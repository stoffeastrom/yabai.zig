const std = @import("std");
const Window = @import("Window.zig");
const Space = @import("Space.zig");
const geometry = @import("geometry.zig");

const log = std.log.scoped(.view);
const Rect = geometry.Rect;

/// Binary Space Partition tree for window tiling.
/// This is a pure layout structure - it does NOT track which windows exist.
/// Windows are assigned to leaf nodes at layout time based on external data.
pub const View = @This();

/// Split direction
pub const Split = enum {
    none,
    vertical, // Y-axis split (side by side)
    horizontal, // X-axis split (top/bottom)

    pub fn fromAreaRatio(width: f64, height: f64) Split {
        return if (width >= height) .vertical else .horizontal;
    }
};

/// Layout type
pub const Layout = enum {
    bsp,
    stack,
    float,
};

/// Direction for navigation/insertion
pub const Direction = enum(u8) {
    north = 0,
    east = 1,
    south = 2,
    west = 3,
};

/// Padding configuration
pub const Padding = struct {
    top: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
    right: i32 = 0,

    pub fn apply(self: Padding, area: Rect) Rect {
        return .{
            .x = area.x + @as(f64, @floatFromInt(self.left)),
            .y = area.y + @as(f64, @floatFromInt(self.top)),
            .width = area.width - @as(f64, @floatFromInt(self.left + self.right)),
            .height = area.height - @as(f64, @floatFromInt(self.top + self.bottom)),
        };
    }
};

/// A node in the BSP tree - represents a region that can be split
pub const Node = struct {
    area: Rect = .{},
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,

    split: Split = .none,
    ratio: f32 = 0.5,

    pub fn isLeaf(self: *const Node) bool {
        return self.left == null and self.right == null;
    }

    pub fn isLeftChild(self: *const Node) bool {
        const p = self.parent orelse return false;
        return p.left == self;
    }

    pub fn isRightChild(self: *const Node) bool {
        const p = self.parent orelse return false;
        return p.right == self;
    }

    /// Find first leaf node (leftmost)
    pub fn findFirstLeaf(self: *Node) *Node {
        var node = self;
        while (!node.isLeaf()) {
            node = node.left.?;
        }
        return node;
    }

    /// Find last leaf node (rightmost)
    pub fn findLastLeaf(self: *Node) *Node {
        var node = self;
        while (!node.isLeaf()) {
            node = node.right.?;
        }
        return node;
    }

    /// Find next leaf in tree order
    pub fn findNextLeaf(self: *Node) ?*Node {
        const parent = self.parent orelse return null;

        if (self.isRightChild()) {
            return parent.findNextLeaf();
        }

        if (parent.right) |right| {
            if (right.isLeaf()) {
                return right;
            }
            return right.findFirstLeaf();
        }

        return null;
    }

    /// Find previous leaf in tree order
    pub fn findPrevLeaf(self: *Node) ?*Node {
        const parent = self.parent orelse return null;

        if (self.isLeftChild()) {
            return parent.findPrevLeaf();
        }

        if (parent.left) |left| {
            if (left.isLeaf()) {
                return left;
            }
            return left.findLastLeaf();
        }

        return null;
    }
};

/// Window frame assignment (result of layout calculation)
pub const WindowFrame = struct {
    window_id: Window.Id,
    frame: Rect,
};

// View fields
allocator: std.mem.Allocator,
space_id: Space.Id,
root: *Node,
layout: Layout = .bsp,
padding: Padding = .{},
window_gap: i32 = 0,
split_ratio: f32 = 0.5,
split_type: Split = .vertical,
auto_balance: bool = false,

pub fn init(allocator: std.mem.Allocator, space_id: Space.Id) !*View {
    const root = try allocator.create(Node);
    root.* = .{};

    const view = try allocator.create(View);
    view.* = .{
        .allocator = allocator,
        .space_id = space_id,
        .root = root,
    };
    return view;
}

pub fn deinit(self: *View) void {
    self.destroyNode(self.root);
    self.allocator.destroy(self);
}

fn destroyNode(self: *View, node: *Node) void {
    if (node.left) |left| self.destroyNode(left);
    if (node.right) |right| self.destroyNode(right);
    self.allocator.destroy(node);
}

/// Set the root area (typically from display bounds)
pub fn setArea(self: *View, area: Rect) void {
    self.root.area = self.padding.apply(area);
}

/// Count leaf nodes in the tree
pub fn leafCount(self: *View) usize {
    return self.countLeaves(self.root);
}

fn countLeaves(self: *View, node: *Node) usize {
    if (node.isLeaf()) return 1;
    return self.countLeaves(node.left.?) + self.countLeaves(node.right.?);
}

/// Ensure tree has exactly n leaf nodes by growing or shrinking
pub fn ensureLeafCount(self: *View, n: usize) !void {
    if (n == 0) {
        // Reset to single empty leaf
        self.destroyNode(self.root);
        self.root = try self.allocator.create(Node);
        self.root.* = .{};
        return;
    }

    const current = self.leafCount();

    if (current < n) {
        // Need to grow - split leaves until we have enough
        var to_add = n - current;
        while (to_add > 0) {
            const leaf = self.findMinDepthLeaf();
            try self.splitLeaf(leaf);
            to_add -= 1;
        }
    } else if (current > n) {
        // Need to shrink - collapse nodes
        var to_remove = current - n;
        while (to_remove > 0) {
            if (self.collapseOneLeaf()) {
                to_remove -= 1;
            } else {
                break; // Can't collapse further
            }
        }
    }

    // Recalculate areas
    self.updateNodeAreas(self.root);
}

/// Split a leaf node into two
fn splitLeaf(self: *View, node: *Node) !void {
    const left = try self.allocator.create(Node);
    const right = try self.allocator.create(Node);

    left.* = .{ .parent = node };
    right.* = .{ .parent = node };

    // Determine split direction based on area ratio
    const split = if (self.split_type != .none)
        self.split_type
    else
        Split.fromAreaRatio(node.area.width, node.area.height);

    node.left = left;
    node.right = right;
    node.split = split;
    node.ratio = self.split_ratio;
}

/// Collapse one leaf by removing it and its sibling, replacing parent with sibling
fn collapseOneLeaf(self: *View) bool {
    // Find a leaf that can be collapsed (has a sibling that's also a leaf)
    var node: ?*Node = self.root.findFirstLeaf();
    while (node) |n| {
        const parent = n.parent orelse {
            node = n.findNextLeaf();
            continue;
        };

        const sibling = if (n.isLeftChild()) parent.right.? else parent.left.?;

        if (sibling.isLeaf()) {
            // Can collapse - make parent a leaf
            self.allocator.destroy(n);
            self.allocator.destroy(sibling);
            parent.left = null;
            parent.right = null;
            parent.split = .none;
            return true;
        }

        node = n.findNextLeaf();
    }
    return false;
}

/// Find leaf with minimum depth (for balanced insertion)
fn findMinDepthLeaf(self: *View) *Node {
    // BFS to find first leaf
    var queue: [256]*Node = undefined;
    var read: usize = 0;
    var write: usize = 0;

    queue[write] = self.root;
    write += 1;

    while (read < write and read < 256) {
        const node = queue[read];
        read += 1;

        if (node.isLeaf()) return node;

        if (node.left) |l| {
            queue[write] = l;
            write += 1;
        }
        if (node.right) |r| {
            queue[write] = r;
            write += 1;
        }
    }

    return self.root;
}

/// Update all node areas based on splits and ratios
fn updateNodeAreas(self: *View, node: *Node) void {
    if (node.isLeaf()) return;

    const left = node.left.?;
    const right = node.right.?;
    const gap: f64 = @floatFromInt(self.window_gap);
    const ratio: f64 = node.ratio;

    if (node.split == .vertical) {
        // Side by side
        const left_width = (node.area.width - gap) * ratio;
        const right_width = (node.area.width - gap) * (1.0 - ratio);

        left.area = .{
            .x = node.area.x,
            .y = node.area.y,
            .width = left_width,
            .height = node.area.height,
        };
        right.area = .{
            .x = node.area.x + left_width + gap,
            .y = node.area.y,
            .width = right_width,
            .height = node.area.height,
        };
    } else {
        // Top and bottom
        const left_height = (node.area.height - gap) * ratio;
        const right_height = (node.area.height - gap) * (1.0 - ratio);

        left.area = .{
            .x = node.area.x,
            .y = node.area.y,
            .width = node.area.width,
            .height = left_height,
        };
        right.area = .{
            .x = node.area.x,
            .y = node.area.y + left_height + gap,
            .width = node.area.width,
            .height = right_height,
        };
    }

    // Recurse
    self.updateNodeAreas(left);
    self.updateNodeAreas(right);
}

/// Calculate frames for a list of windows.
/// The tree is resized to match window count, then windows are assigned to leaves in order.
pub fn calculateFrames(self: *View, windows: []const Window.Id, allocator: std.mem.Allocator) ![]WindowFrame {
    if (windows.len == 0) {
        return allocator.alloc(WindowFrame, 0);
    }

    // For float layout, return empty (windows keep their positions)
    if (self.layout == .float) {
        return allocator.alloc(WindowFrame, 0);
    }

    // For stack layout, all windows get the root area
    if (self.layout == .stack) {
        var frames = try allocator.alloc(WindowFrame, windows.len);
        for (windows, 0..) |wid, i| {
            frames[i] = .{ .window_id = wid, .frame = self.root.area };
        }
        return frames;
    }

    // BSP layout - ensure we have the right number of leaves
    try self.ensureLeafCount(windows.len);

    // Collect leaf areas in order and pair with windows
    var frames = try allocator.alloc(WindowFrame, windows.len);
    errdefer allocator.free(frames);

    var leaf: ?*Node = self.root.findFirstLeaf();
    var i: usize = 0;

    while (leaf) |node| : (i += 1) {
        if (i >= windows.len) break;
        frames[i] = .{ .window_id = windows[i], .frame = node.area };
        leaf = node.findNextLeaf();
    }

    return frames;
}

/// Balance the tree (equalize ratios)
pub fn balance(self: *View) void {
    self.balanceNode(self.root);
    self.updateNodeAreas(self.root);
}

fn balanceNode(self: *View, node: *Node) void {
    if (node.isLeaf()) return;

    node.ratio = 0.5;
    self.balanceNode(node.left.?);
    self.balanceNode(node.right.?);
}

/// Rotate the tree
pub fn rotate(self: *View, degrees: i32) void {
    self.rotateNode(self.root, degrees);
    self.updateNodeAreas(self.root);
}

fn rotateNode(self: *View, node: *Node, degrees: i32) void {
    if ((degrees == 90 and node.split == .vertical) or
        (degrees == 270 and node.split == .horizontal) or
        (degrees == 180))
    {
        // Swap children
        const temp = node.left;
        node.left = node.right;
        node.right = temp;
        node.ratio = 1.0 - node.ratio;
    }

    if (degrees != 180) {
        node.split = switch (node.split) {
            .vertical => .horizontal,
            .horizontal => .vertical,
            else => node.split,
        };
    }

    if (!node.isLeaf()) {
        self.rotateNode(node.left.?, degrees);
        self.rotateNode(node.right.?, degrees);
    }
}

/// Mirror the tree along an axis
pub fn mirror(self: *View, axis: Split) void {
    self.mirrorNode(self.root, axis);
    self.updateNodeAreas(self.root);
}

fn mirrorNode(self: *View, node: *Node, axis: Split) void {
    if (!node.isLeaf()) {
        self.mirrorNode(node.left.?, axis);
        self.mirrorNode(node.right.?, axis);

        if (node.split == axis) {
            const temp = node.left;
            node.left = node.right;
            node.right = temp;
        }
    }
}

/// Adjust the ratio of a specific leaf's parent split
pub fn adjustRatio(self: *View, leaf_index: usize, delta: f32) void {
    var node: ?*Node = self.root.findFirstLeaf();
    var i: usize = 0;

    while (node) |n| : (i += 1) {
        if (i == leaf_index) {
            if (n.parent) |parent| {
                parent.ratio = std.math.clamp(parent.ratio + delta, 0.1, 0.9);
                self.updateNodeAreas(self.root);
            }
            return;
        }
        node = n.findNextLeaf();
    }
}

// ============================================================================
// Tests
// ============================================================================

test "View init/deinit" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    try std.testing.expectEqual(Layout.bsp, view.layout);
    try std.testing.expect(view.root.isLeaf());
}

test "View leafCount and ensureLeafCount" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.setArea(Rect.init(0, 0, 1000, 1000));

    try std.testing.expectEqual(@as(usize, 1), view.leafCount());

    try view.ensureLeafCount(3);
    try std.testing.expectEqual(@as(usize, 3), view.leafCount());

    try view.ensureLeafCount(1);
    try std.testing.expectEqual(@as(usize, 1), view.leafCount());

    try view.ensureLeafCount(0);
    try std.testing.expectEqual(@as(usize, 1), view.leafCount()); // Can't go below 1
}

test "View calculateFrames" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.setArea(Rect.init(0, 0, 1000, 1000));

    const windows = [_]Window.Id{ 100, 200, 300 };
    const frames = try view.calculateFrames(&windows, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqual(@as(Window.Id, 100), frames[0].window_id);
    try std.testing.expectEqual(@as(Window.Id, 200), frames[1].window_id);
    try std.testing.expectEqual(@as(Window.Id, 300), frames[2].window_id);
}

test "View calculateFrames with gap" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.window_gap = 10;
    view.setArea(Rect.init(0, 0, 1000, 1000));

    const windows = [_]Window.Id{ 100, 200 };
    const frames = try view.calculateFrames(&windows, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);

    // With 50/50 split and 10px gap on 1000px width:
    // Left: 0, width = (1000-10)*0.5 = 495
    // Right: x = 495+10 = 505, width = 495
    const left = if (frames[0].frame.x < frames[1].frame.x) frames[0] else frames[1];
    const right = if (frames[0].frame.x < frames[1].frame.x) frames[1] else frames[0];

    try std.testing.expectEqual(@as(f64, 0), left.frame.x);
    try std.testing.expectApproxEqAbs(@as(f64, 495), left.frame.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 505), right.frame.x, 0.01);
}

test "View stack layout" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.layout = .stack;
    view.setArea(Rect.init(0, 0, 1000, 1000));

    const windows = [_]Window.Id{ 100, 200, 300 };
    const frames = try view.calculateFrames(&windows, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    // All windows should have the same frame (root area)
    try std.testing.expectEqual(frames[0].frame.x, frames[1].frame.x);
    try std.testing.expectEqual(frames[0].frame.width, frames[2].frame.width);
}

test "View float layout" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.layout = .float;
    view.setArea(Rect.init(0, 0, 1000, 1000));

    const windows = [_]Window.Id{ 100, 200 };
    const frames = try view.calculateFrames(&windows, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    // Float returns empty - windows keep their positions
    try std.testing.expectEqual(@as(usize, 0), frames.len);
}

test "View rotate" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.setArea(Rect.init(0, 0, 1000, 1000));

    // Create a split
    try view.ensureLeafCount(2);
    try std.testing.expectEqual(Split.vertical, view.root.split);

    view.rotate(90);
    try std.testing.expectEqual(Split.horizontal, view.root.split);
}

test "View balance" {
    const view = try View.init(std.testing.allocator, 12345);
    defer view.deinit();

    view.setArea(Rect.init(0, 0, 1000, 1000));

    try view.ensureLeafCount(2);
    view.root.ratio = 0.7;

    view.balance();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), view.root.ratio, 0.01);
}

test "Padding.apply" {
    const padding = Padding{ .top = 10, .bottom = 20, .left = 30, .right = 40 };
    const area = Rect.init(0, 0, 1000, 800);
    const result = padding.apply(area);

    try std.testing.expectEqual(@as(f64, 30), result.x);
    try std.testing.expectEqual(@as(f64, 10), result.y);
    try std.testing.expectEqual(@as(f64, 930), result.width);
    try std.testing.expectEqual(@as(f64, 770), result.height);
}

test "Split.fromAreaRatio" {
    try std.testing.expectEqual(Split.vertical, Split.fromAreaRatio(100, 50));
    try std.testing.expectEqual(Split.horizontal, Split.fromAreaRatio(50, 100));
    try std.testing.expectEqual(Split.vertical, Split.fromAreaRatio(100, 100));
}
