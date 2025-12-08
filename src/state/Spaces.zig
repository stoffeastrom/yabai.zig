const std = @import("std");
const c = @import("../platform/c.zig");
const Space = @import("../core/Space.zig");
const View = @import("../core/View.zig");
const Window = @import("../core/Window.zig");
const geometry = @import("../core/geometry.zig");
const skylight = @import("../platform/skylight.zig");
const Windows = @import("Windows.zig");
const ManagedHashMap = @import("ManagedHashMap.zig").ManagedHashMap;
const LabelMap = @import("LabelMap.zig").LabelMap;

const log = std.log.scoped(.spaces);

pub const Spaces = @This();

/// Layout type for spaces
pub const LayoutType = enum {
    bsp,
    stack,
    float,
};

/// Split direction
pub const SplitType = enum {
    none,
    vertical,
    horizontal,
};

/// Space label mapping
pub const SpaceLabel = struct {
    sid: Space.Id,
    label: []const u8,
};

/// Padding configuration
pub const Padding = struct {
    top: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
    right: i32 = 0,
};

// State
allocator: std.mem.Allocator,
labels: LabelMap(Space.Id) = undefined,
views: ManagedHashMap(Space.Id, *View, null) = undefined,
current_space_id: ?Space.Id = null,
last_space_id: ?Space.Id = null,

// Global configuration defaults
layout: LayoutType = .bsp,
split_ratio: f32 = 0.5,
split_type: SplitType = .vertical,
window_gap: i32 = 0,
padding: Padding = .{},
auto_balance: bool = false,

pub fn init(allocator: std.mem.Allocator) Spaces {
    return .{
        .allocator = allocator,
        .labels = LabelMap(Space.Id).init(allocator),
        .views = ManagedHashMap(Space.Id, *View, null).init(allocator),
    };
}

pub fn deinit(self: *Spaces) void {
    self.views.deinit();
    self.labels.deinit();
}

/// Set a label for a space
pub fn setLabel(self: *Spaces, sid: Space.Id, label: []const u8) !void {
    try self.labels.set(sid, label);
}

/// Get space ID for a label
pub fn getSpaceForLabel(self: *const Spaces, label: []const u8) ?Space.Id {
    return self.labels.getId(label);
}

/// Get label for a space
pub fn getLabelForSpace(self: *const Spaces, sid: Space.Id) ?[]const u8 {
    return self.labels.getLabel(sid);
}

/// Remove label for a space
pub fn removeLabel(self: *Spaces, sid: Space.Id) bool {
    return self.labels.remove(sid);
}

/// Clear all space labels
pub fn clearLabels(self: *Spaces) void {
    self.labels.clear();
}

/// Set current space
pub fn setCurrentSpace(self: *Spaces, sid: Space.Id) void {
    if (self.current_space_id) |current| {
        if (current != sid) {
            self.last_space_id = current;
        }
    }
    self.current_space_id = sid;
}

/// Get the active (current) space ID
pub fn getActiveSpace() ?Space.Id {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    const display = sl.SLSGetDisplayForActiveSpace(cid);
    if (display == 0) return null;

    // Get the space list for main display
    const query = sl.SLSWindowQueryWindows(cid, null, 0);
    if (query == null) return null;
    defer c.c.CFRelease(query);

    // Use current space for main display
    const uuid = sl.SLSCopyActiveMenuBarDisplayIdentifier(cid);
    if (uuid == null) return null;
    defer c.c.CFRelease(uuid);

    return sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
}

/// Get first space across all displays
pub fn getFirstSpace() ?Space.Id {
    return getSpaceByIndex(1);
}

/// Get all space IDs (allocates) - in Mission Control order
pub fn getAllSpaces(allocator: std.mem.Allocator) ![]Space.Id {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    const all_spaces = sl.SLSCopyManagedDisplaySpaces(cid);
    if (all_spaces == null) return &[_]Space.Id{};
    defer c.c.CFRelease(all_spaces);

    var result = std.ArrayList(Space.Id){};
    errdefer result.deinit(allocator);

    const display_count: usize = @intCast(c.c.CFArrayGetCount(all_spaces));
    for (0..display_count) |i| {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(all_spaces, @intCast(i)));
        const spaces_key = c.cfstr("Spaces");
        defer c.c.CFRelease(spaces_key);
        const spaces: c.CFArrayRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, spaces_key));
        if (spaces == null) continue;

        const space_count: usize = @intCast(c.c.CFArrayGetCount(spaces));
        for (0..space_count) |j| {
            const space_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces, @intCast(j)));
            const id_key = c.cfstr("id64");
            defer c.c.CFRelease(id_key);
            const sid_ref: c.c.CFNumberRef = @ptrCast(c.c.CFDictionaryGetValue(space_dict, id_key));
            if (sid_ref != null) {
                var sid: Space.Id = 0;
                _ = c.c.CFNumberGetValue(sid_ref, c.c.kCFNumberSInt64Type, &sid);
                try result.append(allocator, sid);
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Get space ID by Mission Control index (1-based)
/// Index is global across all displays in display order
pub fn getSpaceByIndex(index: u32) ?Space.Id {
    if (index == 0) return null;

    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    const all_spaces = sl.SLSCopyManagedDisplaySpaces(cid);
    if (all_spaces == null) return null;
    defer c.c.CFRelease(all_spaces);

    var current_index: u32 = 1;
    const display_count: usize = @intCast(c.c.CFArrayGetCount(all_spaces));

    for (0..display_count) |i| {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(all_spaces, @intCast(i)));
        const spaces_key = c.cfstr("Spaces");
        defer c.c.CFRelease(spaces_key);
        const spaces: c.CFArrayRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, spaces_key));
        if (spaces == null) continue;

        const space_count: usize = @intCast(c.c.CFArrayGetCount(spaces));
        for (0..space_count) |j| {
            if (current_index == index) {
                const space_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces, @intCast(j)));
                const id_key = c.cfstr("id64");
                defer c.c.CFRelease(id_key);
                const sid_ref: c.c.CFNumberRef = @ptrCast(c.c.CFDictionaryGetValue(space_dict, id_key));
                if (sid_ref == null) return null;
                var sid: Space.Id = 0;
                _ = c.c.CFNumberGetValue(sid_ref, c.c.kCFNumberSInt64Type, &sid);
                return sid;
            }
            current_index += 1;
        }
    }

    return null;
}

/// Get Mission Control index for a space ID (1-based)
pub fn getIndexForSpace(sid: Space.Id) ?u32 {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    const all_spaces = sl.SLSCopyManagedDisplaySpaces(cid);
    if (all_spaces == null) return null;
    defer c.c.CFRelease(all_spaces);

    var current_index: u32 = 1;
    const display_count: usize = @intCast(c.c.CFArrayGetCount(all_spaces));

    for (0..display_count) |i| {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(all_spaces, @intCast(i)));
        const spaces_key = c.cfstr("Spaces");
        defer c.c.CFRelease(spaces_key);
        const spaces: c.CFArrayRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, spaces_key));
        if (spaces == null) continue;

        const space_count: usize = @intCast(c.c.CFArrayGetCount(spaces));
        for (0..space_count) |j| {
            const space_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces, @intCast(j)));
            const id_key = c.cfstr("id64");
            defer c.c.CFRelease(id_key);
            const sid_ref: c.c.CFNumberRef = @ptrCast(c.c.CFDictionaryGetValue(space_dict, id_key));
            if (sid_ref != null) {
                var space_sid: Space.Id = 0;
                _ = c.c.CFNumberGetValue(sid_ref, c.c.kCFNumberSInt64Type, &space_sid);
                if (space_sid == sid) {
                    return current_index;
                }
            }
            current_index += 1;
        }
    }

    return null;
}

// ============================================================================
// View/Layout Management
// ============================================================================

/// Get or create a View for a space
pub fn getOrCreateView(self: *Spaces, sid: Space.Id) !*View {
    if (self.views.get(sid)) |view| {
        return view;
    }

    // Create new view for this space
    const view = try View.init(self.allocator, sid);
    errdefer view.deinit();

    // Apply global configuration
    view.layout = switch (self.layout) {
        .bsp => .bsp,
        .stack => .stack,
        .float => .float,
    };
    view.split_ratio = self.split_ratio;
    view.split_type = switch (self.split_type) {
        .none => .none,
        .vertical => .vertical,
        .horizontal => .horizontal,
    };
    view.window_gap = self.window_gap;
    view.padding = .{
        .top = self.padding.top,
        .bottom = self.padding.bottom,
        .left = self.padding.left,
        .right = self.padding.right,
    };
    view.auto_balance = self.auto_balance;

    // ManagedHashMap handles cleanup if key exists (shouldn't happen here)
    try self.views.put(sid, view);
    return view;
}

/// Get view for a space (if exists)
pub fn getView(self: *Spaces, sid: Space.Id) ?*View {
    return self.views.get(sid);
}

/// Remove view for a space (ManagedHashMap handles cleanup)
pub fn removeView(self: *Spaces, sid: Space.Id) void {
    _ = self.views.remove(sid);
}

/// Get count of views
pub fn count(self: *const Spaces) usize {
    return self.views.count();
}

/// Get capacity of views
pub fn capacity(self: *const Spaces) usize {
    return self.views.capacity();
}

/// Apply layout for a space - gets tileable windows from Windows and tiles them
pub fn applyLayout(self: *Spaces, sid: Space.Id, bounds: geometry.Rect, windows_state: *Windows) !void {
    const view = try self.getOrCreateView(sid);

    // Get tileable windows from Windows (single source of truth)
    const windows = try windows_state.getTileableWindowsForSpace(self.allocator, sid);
    defer self.allocator.free(windows);

    log.info("applyLayout: space={} bounds=({d:.0},{d:.0} {d:.0}x{d:.0}) windows={}", .{
        sid,
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        windows.len,
    });

    if (windows.len == 0) {
        return;
    }

    // Set view area and calculate frames
    view.setArea(bounds);
    const frames = try view.calculateFrames(windows, self.allocator);
    defer self.allocator.free(frames);

    // Apply each frame to its window using cached ax_ref (works cross-space)
    for (frames) |frame| {
        const entry = windows_state.getWindow(frame.window_id) orelse {
            log.err("applyLayout: window {} not found in WindowTable", .{frame.window_id});
            continue;
        };
        Window.setFrameByRef(entry.ax_ref, frame.window_id, frame.frame) catch |e| {
            log.err("applyLayout: setFrameByRef failed for wid={}: {}", .{ frame.window_id, e });
            continue;
        };
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Spaces init/deinit" {
    var sm = Spaces.init(std.testing.allocator);
    defer sm.deinit();

    try std.testing.expectEqual(@as(?Space.Id, null), sm.current_space_id);
    try std.testing.expectEqual(LayoutType.bsp, sm.layout);
}

test "Spaces labels" {
    var sm = Spaces.init(std.testing.allocator);
    defer sm.deinit();

    try sm.setLabel(12345, "main");
    try std.testing.expectEqual(@as(?Space.Id, 12345), sm.getSpaceForLabel("main"));
    try std.testing.expect(std.mem.eql(u8, "main", sm.getLabelForSpace(12345).?));

    // Update label
    try sm.setLabel(12345, "primary");
    try std.testing.expectEqual(@as(?Space.Id, null), sm.getSpaceForLabel("main"));
    try std.testing.expectEqual(@as(?Space.Id, 12345), sm.getSpaceForLabel("primary"));

    // Remove label
    try std.testing.expect(sm.removeLabel(12345));
    try std.testing.expectEqual(@as(?Space.Id, null), sm.getSpaceForLabel("primary"));
    try std.testing.expect(!sm.removeLabel(12345)); // Already removed
}

test "Spaces current space tracking" {
    var sm = Spaces.init(std.testing.allocator);
    defer sm.deinit();

    sm.setCurrentSpace(100);
    try std.testing.expectEqual(@as(?Space.Id, 100), sm.current_space_id);
    try std.testing.expectEqual(@as(?Space.Id, null), sm.last_space_id);

    sm.setCurrentSpace(200);
    try std.testing.expectEqual(@as(?Space.Id, 200), sm.current_space_id);
    try std.testing.expectEqual(@as(?Space.Id, 100), sm.last_space_id);
}

test "Spaces view creation" {
    var sm = Spaces.init(std.testing.allocator);
    defer sm.deinit();

    const view = try sm.getOrCreateView(12345);
    try std.testing.expectEqual(@as(Space.Id, 12345), view.space_id);

    // Same view returned on second call
    const view2 = try sm.getOrCreateView(12345);
    try std.testing.expectEqual(view, view2);
}

test "Spaces applies global config to views" {
    var sm = Spaces.init(std.testing.allocator);
    defer sm.deinit();

    sm.window_gap = 10;
    sm.split_ratio = 0.6;
    sm.layout = .stack;

    const view = try sm.getOrCreateView(12345);
    try std.testing.expectEqual(@as(i32, 10), view.window_gap);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), view.split_ratio, 0.001);
    try std.testing.expectEqual(View.Layout.stack, view.layout);
}

test "Spaces removeView" {
    var sm = Spaces.init(std.testing.allocator);
    defer sm.deinit();

    _ = try sm.getOrCreateView(100);
    try std.testing.expect(sm.views.contains(100));

    sm.removeView(100);
    try std.testing.expect(!sm.views.contains(100));

    // Removing again should not crash
    sm.removeView(100);
}
