const std = @import("std");
const c = @import("../platform/c.zig");
const geometry = @import("geometry.zig");
const skylight = @import("../platform/skylight.zig");
const Space = @import("Space.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;

pub const Id = u32;

// Dictionary key strings (created once, cached)
var key_display_identifier: c.CFStringRef = null;
var key_spaces: c.CFStringRef = null;
var key_id64: c.CFStringRef = null;

fn getKeyDisplayIdentifier() c.CFStringRef {
    if (key_display_identifier == null) {
        key_display_identifier = c.cfstr("Display Identifier");
    }
    return key_display_identifier.?;
}

fn getKeySpaces() c.CFStringRef {
    if (key_spaces == null) {
        key_spaces = c.cfstr("Spaces");
    }
    return key_spaces.?;
}

fn getKeyId64() c.CFStringRef {
    if (key_id64 == null) {
        key_id64 = c.cfstr("id64");
    }
    return key_id64.?;
}

/// Query flags for serialization
pub const Property = enum(u64) {
    id = 0x01,
    uuid = 0x02,
    index = 0x04,
    label = 0x08,
    frame = 0x10,
    spaces = 0x20,
    has_focus = 0x40,
};

/// Errors that can occur during display operations
pub const Error = error{
    SkyLightError,
    InvalidDisplay,
    OutOfMemory,
};

// ============================================================================
// Display operations using display ID (stateless)
// ============================================================================

/// Get display UUID as string. Caller must CFRelease.
pub fn getUUID(did: Id) ?c.CFStringRef {
    const uuid_ref = c.c.CGDisplayCreateUUIDFromDisplayID(did);
    if (uuid_ref == null) return null;
    defer c.c.CFRelease(uuid_ref);

    const uuid_str = c.c.CFUUIDCreateString(null, uuid_ref);
    return uuid_str;
}

/// Get display ID from UUID string
pub fn getId(uuid: c.CFStringRef) Id {
    // Need to parse UUID string back to CFUUID first
    const uuid_ref = c.c.CFUUIDCreateFromString(null, uuid);
    if (uuid_ref == null) return 0;
    defer c.c.CFRelease(uuid_ref);

    return c.c.CGDisplayGetDisplayIDFromUUID(uuid_ref);
}

/// Get display bounds (frame in global coordinates)
pub fn getBounds(did: Id) Rect {
    const cg = c.c.CGDisplayBounds(did);
    return Rect.fromCG(cg);
}

/// Get display center point
pub fn getCenter(did: Id) Point {
    return getBounds(did).center();
}

/// Get current space ID for display
pub fn getCurrentSpace(did: Id) ?Space.Id {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    const uuid = getUUID(did) orelse return null;
    defer c.c.CFRelease(uuid);

    const sid = sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
    return if (sid != 0) sid else null;
}

/// Get space count for display
pub fn getSpaceCount(did: Id) u32 {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();

    const uuid = getUUID(did) orelse return 0;
    defer c.c.CFRelease(uuid);

    // Get all display spaces and count spaces for this display
    const all_spaces = sl.SLSCopyManagedDisplaySpaces(cid);
    if (all_spaces == null) return 0;
    defer c.c.CFRelease(all_spaces);

    const count = c.c.CFArrayGetCount(all_spaces);
    var total: u32 = 0;

    for (0..@intCast(count)) |i| {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(all_spaces, @intCast(i)));
        const display_uuid: c.CFStringRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, getKeyDisplayIdentifier()));

        if (display_uuid != null and c.c.CFStringCompare(display_uuid.?, uuid, 0) == c.c.kCFCompareEqualTo) {
            const spaces: c.CFArrayRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, getKeySpaces()));
            if (spaces != null) {
                total = @intCast(c.c.CFArrayGetCount(spaces.?));
            }
            break;
        }
    }

    return total;
}

/// Get space list for display (allocates)
pub fn getSpaceList(allocator: std.mem.Allocator, did: Id) ![]Space.Id {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    const uuid = getUUID(did) orelse return error.InvalidDisplay;
    defer c.c.CFRelease(uuid);

    const all_spaces = sl.SLSCopyManagedDisplaySpaces(cid);
    if (all_spaces == null) return error.SkyLightError;
    defer c.c.CFRelease(all_spaces);

    const display_count = c.c.CFArrayGetCount(all_spaces);

    for (0..@intCast(display_count)) |i| {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(all_spaces, @intCast(i)));
        const display_uuid: c.CFStringRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, getKeyDisplayIdentifier()));

        if (display_uuid != null and c.c.CFStringCompare(display_uuid.?, uuid, 0) == c.c.kCFCompareEqualTo) {
            const spaces: c.CFArrayRef = @ptrCast(c.c.CFDictionaryGetValue(display_dict, getKeySpaces()));
            if (spaces == null) return &[_]Space.Id{};

            const space_count: usize = @intCast(c.c.CFArrayGetCount(spaces.?));
            if (space_count == 0) return &[_]Space.Id{};

            const result = try allocator.alloc(Space.Id, space_count);
            errdefer allocator.free(result);

            for (0..space_count) |j| {
                const space_dict: c.CFDictionaryRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces.?, @intCast(j)));
                const space_id_num: c.c.CFNumberRef = @ptrCast(c.c.CFDictionaryGetValue(space_dict, getKeyId64()));

                if (space_id_num != null) {
                    var sid: Space.Id = 0;
                    _ = c.c.CFNumberGetValue(space_id_num.?, c.c.kCFNumberSInt64Type, &sid);
                    result[j] = sid;
                } else {
                    result[j] = 0;
                }
            }

            return result;
        }
    }

    return &[_]Space.Id{};
}

/// Get menubar height for display
pub fn getMenubarHeight(did: Id) u32 {
    const sl = skylight.get() catch return 0;
    var height: u32 = 0;
    _ = sl.SLSGetDisplayMenubarHeight(did, &height);
    return height;
}

/// Check if menubar autohide is enabled
pub fn isMenubarAutohideEnabled() bool {
    const sl = skylight.get() catch return false;
    const cid = sl.SLSMainConnectionID();
    var enabled: c_int = 0;
    if (sl.SLSGetMenuBarAutohideEnabled(cid, &enabled) != 0) return false;
    return enabled != 0;
}

/// Get dock rect and position
pub fn getDockRect() ?Rect {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    var rect: c.CGRect = undefined;
    var reason: c_int = undefined;
    if (sl.SLSGetDockRectWithReason(cid, &rect, &reason) != 0) return null;
    return Rect.fromCG(rect);
}

/// Get display bounds constrained by dock and menubar
pub fn getBoundsConstrained(did: Id, ignore_external_bar: bool) Rect {
    var bounds = getBounds(did);

    // Adjust for menubar (only on primary display typically)
    const menubar_height = getMenubarHeight(did);
    if (menubar_height > 0) {
        bounds.y += @floatFromInt(menubar_height);
        bounds.height -= @floatFromInt(menubar_height);
    }

    // Adjust for dock if on this display
    if (!ignore_external_bar) {
        if (getDockRect()) |dock| {
            if (dock.intersects(bounds)) {
                // Dock is on this display - determine which edge
                if (dock.y == bounds.y + bounds.height - dock.height) {
                    // Bottom dock
                    bounds.height -= dock.height;
                } else if (dock.x == bounds.x) {
                    // Left dock
                    bounds.x += dock.width;
                    bounds.width -= dock.width;
                } else if (dock.x == bounds.x + bounds.width - dock.width) {
                    // Right dock
                    bounds.width -= dock.width;
                }
            }
        }
    }

    return bounds;
}

/// Check if display is animating (space switch in progress)
pub fn isAnimating(did: Id) bool {
    const sl = skylight.get() catch return false;
    const cid = sl.SLSMainConnectionID();

    const uuid = getUUID(did) orelse return false;
    defer c.c.CFRelease(uuid);

    return sl.SLSManagedDisplayIsAnimating(cid, uuid);
}

/// Get all managed displays. Caller must CFRelease.
pub fn getManagedDisplays() ?c.CFArrayRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    return sl.SLSCopyManagedDisplays(cid);
}

/// Get display for point. Caller must CFRelease.
pub fn getDisplayForPoint(point: Point) ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const uuid = sl.SLSCopyBestManagedDisplayForPoint(cid, point.toCG());
    return if (uuid != null) uuid else null;
}

/// Get display for rect. Caller must CFRelease.
pub fn getDisplayForRect(rect: Rect) ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const uuid = sl.SLSCopyBestManagedDisplayForRect(cid, rect.toCG());
    return if (uuid != null) uuid else null;
}

/// Get active menubar display UUID. Caller must CFRelease.
pub fn getActiveMenubarDisplay() ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const uuid = sl.SLSCopyActiveMenuBarDisplayIdentifier(cid);
    return if (uuid != null) uuid else null;
}

// ============================================================================
// Tests
// ============================================================================

test "Property enum values" {
    try std.testing.expectEqual(@as(u64, 0x01), @intFromEnum(Property.id));
    try std.testing.expectEqual(@as(u64, 0x10), @intFromEnum(Property.frame));
    try std.testing.expectEqual(@as(u64, 0x40), @intFromEnum(Property.has_focus));
}

test "getBounds returns valid rect for main display" {
    const main_id = c.c.CGMainDisplayID();
    const bounds = getBounds(main_id);

    // Main display should have positive dimensions
    try std.testing.expect(bounds.width > 0);
    try std.testing.expect(bounds.height > 0);
}

test "getCenter returns point within bounds" {
    const main_id = c.c.CGMainDisplayID();
    const bounds = getBounds(main_id);
    const center_pt = getCenter(main_id);

    try std.testing.expect(bounds.contains(center_pt));
}

test "getUUID returns valid string for main display" {
    const main_id = c.c.CGMainDisplayID();
    const uuid = getUUID(main_id);
    try std.testing.expect(uuid != null);
    if (uuid) |u| {
        defer c.c.CFRelease(u);
        // UUID should have reasonable length
        const len = c.c.CFStringGetLength(u);
        try std.testing.expect(len > 0);
    }
}

test "getId roundtrips with getUUID" {
    const main_id = c.c.CGMainDisplayID();
    const uuid = getUUID(main_id) orelse return;
    defer c.c.CFRelease(uuid);

    const back_id = getId(uuid);
    try std.testing.expectEqual(main_id, back_id);
}
