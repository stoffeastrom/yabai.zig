const std = @import("std");
const c = @import("../platform/c.zig");
const Display = @import("../core/Display.zig");
const skylight = @import("../platform/skylight.zig");
const geometry = @import("../core/geometry.zig");
const LabelMap = @import("LabelMap.zig").LabelMap;

const Point = geometry.Point;
const Rect = geometry.Rect;

pub const Displays = @This();

/// Display arrangement order
pub const ArrangementOrder = enum {
    default,
    horizontal, // X
    vertical, // Y
};

/// External bar mode
pub const ExternalBarMode = enum {
    off,
    main,
    all,
};

/// Dock orientation
pub const DockOrientation = enum(c_int) {
    bottom = 2,
    left = 3,
    right = 4,

    pub fn fromInt(val: c_int) ?DockOrientation {
        return switch (val) {
            2 => .bottom,
            3 => .left,
            4 => .right,
            else => null,
        };
    }
};

// State
allocator: std.mem.Allocator,
labels: LabelMap(Display.Id) = undefined,
current_display_id: ?Display.Id = null,
last_display_id: ?Display.Id = null,

// Configuration
arrangement_order: ArrangementOrder = .default,
external_bar_mode: ExternalBarMode = .off,
external_bar_top: i32 = 0,
external_bar_bottom: i32 = 0,

pub fn init(allocator: std.mem.Allocator) Displays {
    return .{
        .allocator = allocator,
        .labels = LabelMap(Display.Id).init(allocator),
    };
}

pub fn deinit(self: *Displays) void {
    self.labels.deinit();
}

/// Set a label for a display
pub fn setLabel(self: *Displays, did: Display.Id, label: []const u8) !void {
    try self.labels.set(did, label);
}

/// Get display ID for a label
pub fn getDisplayForLabel(self: *const Displays, label: []const u8) ?Display.Id {
    return self.labels.getId(label);
}

/// Get label for a display
pub fn getLabelForDisplay(self: *const Displays, did: Display.Id) ?[]const u8 {
    return self.labels.getLabel(did);
}

/// Remove label for a display
pub fn removeLabel(self: *Displays, did: Display.Id) bool {
    return self.labels.remove(did);
}

/// Get count of labels
pub fn labelCount(self: *const Displays) usize {
    return self.labels.count();
}

/// Get capacity of labels
pub fn labelCapacity(self: *const Displays) usize {
    return self.labels.labelCapacity();
}

/// Set current display
pub fn setCurrentDisplay(self: *Displays, did: Display.Id) void {
    if (self.current_display_id) |current| {
        if (current != did) {
            self.last_display_id = current;
        }
    }
    self.current_display_id = did;
}

/// Get the main display ID
pub fn getMainDisplayId() Display.Id {
    return c.c.CGMainDisplayID();
}

/// Get the active display ID (with focused window)
pub fn getActiveDisplayId() ?Display.Id {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const did = sl.SLSGetDisplayForActiveSpace(cid);
    return if (did != 0) did else null;
}

/// Get all active display IDs (allocates)
pub fn getActiveDisplayList(allocator: std.mem.Allocator) ![]Display.Id {
    var count: u32 = 0;
    if (c.c.CGGetActiveDisplayList(0, null, &count) != 0) return &[_]Display.Id{};
    if (count == 0) return &[_]Display.Id{};

    const displays = try allocator.alloc(c.c.CGDirectDisplayID, count);
    errdefer allocator.free(displays);

    if (c.c.CGGetActiveDisplayList(count, displays.ptr, &count) != 0) {
        allocator.free(displays);
        return &[_]Display.Id{};
    }

    return displays;
}

/// Get display at point
pub fn getDisplayAtPoint(point: Point) ?Display.Id {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    const displays = sl.SLSCopyManagedDisplays(cid);
    if (displays == null) return null;
    defer c.c.CFRelease(displays);

    const count: usize = @intCast(c.c.CFArrayGetCount(displays));
    for (0..count) |i| {
        const uuid: c.CFStringRef = @ptrCast(c.c.CFArrayGetValueAtIndex(displays, @intCast(i)));
        const did = c.c.CGDisplayGetDisplayIDFromUUID(uuid);

        var bounds: c.CGRect = undefined;
        if (sl.SLSGetDisplayBounds(did, &bounds) == 0) {
            const rect = Rect.fromCG(bounds);
            if (rect.contains(point)) {
                return did;
            }
        }
    }
    return null;
}

/// Check if a display is animating (space change in progress)
pub fn isDisplayAnimating(did: Display.Id) bool {
    return Display.isAnimating(did);
}

/// Get the number of active displays
pub fn getActiveDisplayCount() u32 {
    var count: u32 = 0;
    _ = c.c.CGGetActiveDisplayList(0, null, &count);
    return count;
}

/// Get display ID by index (1-based)
pub fn getDisplayByIndex(index: u32) ?Display.Id {
    if (index == 0) return null;

    var count: u32 = 0;
    if (c.c.CGGetActiveDisplayList(0, null, &count) != 0) return null;
    if (index > count) return null;

    var displays: [32]c.c.CGDirectDisplayID = undefined;
    const max_count = @min(count, 32);
    if (c.c.CGGetActiveDisplayList(max_count, &displays, &count) != 0) return null;

    if (index <= count) {
        return displays[index - 1];
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "Displays init/deinit" {
    var dm = Displays.init(std.testing.allocator);
    defer dm.deinit();

    try std.testing.expectEqual(@as(?Display.Id, null), dm.current_display_id);
    try std.testing.expectEqual(ArrangementOrder.default, dm.arrangement_order);
}

test "Displays labels" {
    var dm = Displays.init(std.testing.allocator);
    defer dm.deinit();

    try dm.setLabel(1, "main");
    try std.testing.expectEqual(@as(?Display.Id, 1), dm.getDisplayForLabel("main"));
    try std.testing.expect(std.mem.eql(u8, "main", dm.getLabelForDisplay(1).?));

    // Update label
    try dm.setLabel(1, "primary");
    try std.testing.expectEqual(@as(?Display.Id, null), dm.getDisplayForLabel("main"));
    try std.testing.expectEqual(@as(?Display.Id, 1), dm.getDisplayForLabel("primary"));

    // Remove label
    try std.testing.expect(dm.removeLabel(1));
    try std.testing.expect(!dm.removeLabel(1));
}

test "Displays current display tracking" {
    var dm = Displays.init(std.testing.allocator);
    defer dm.deinit();

    dm.setCurrentDisplay(1);
    try std.testing.expectEqual(@as(?Display.Id, 1), dm.current_display_id);
    try std.testing.expectEqual(@as(?Display.Id, null), dm.last_display_id);

    dm.setCurrentDisplay(2);
    try std.testing.expectEqual(@as(?Display.Id, 2), dm.current_display_id);
    try std.testing.expectEqual(@as(?Display.Id, 1), dm.last_display_id);
}
