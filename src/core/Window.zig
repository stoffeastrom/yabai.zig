const std = @import("std");
const c = @import("../platform/c.zig");
const geometry = @import("geometry.zig");
const accessibility = @import("../platform/accessibility.zig");
const skylight = @import("../platform/skylight.zig");

const log = std.log.scoped(.window);

const Rect = geometry.Rect;
const Point = geometry.Point;

pub const Id = u32;

/// Window state flags (packed for efficiency)
pub const Flags = packed struct {
    shadow: bool = true,
    fullscreen: bool = false,
    minimized: bool = false,
    floating: bool = false,
    sticky: bool = false,
    windowed: bool = false,
    movable: bool = true,
    resizable: bool = true,
    hidden: bool = false, // App is hidden (Cmd+H)
};

/// Rule-applied flags
pub const RuleFlags = packed struct {
    managed: bool = false,
    fullscreen: bool = false,
    mff: bool = false,
    mff_value: bool = false,
    _padding: u4 = 0,
};

/// Window notification subscriptions
pub const NotificationMask = packed struct {
    destroyed: bool = false,
    minimized: bool = false,
    deminimized: bool = false,
    _padding: u5 = 0,
};

/// Query flags for serialization
pub const Property = enum(u64) {
    id = 0x000000001,
    pid = 0x000000002,
    app = 0x000000004,
    title = 0x000000008,
    scratchpad = 0x000000010,
    frame = 0x000000020,
    role = 0x000000040,
    subrole = 0x000000080,
    root_window = 0x000000100,
    display = 0x000000200,
    space = 0x000000400,
    level = 0x000000800,
    sub_level = 0x000001000,
    layer = 0x000002000,
    sub_layer = 0x000004000,
    opacity = 0x000008000,
    split_type = 0x000010000,
    split_child = 0x000020000,
    stack_index = 0x000040000,
    can_move = 0x000080000,
    can_resize = 0x000100000,
    has_focus = 0x000200000,
    has_shadow = 0x000400000,
    has_parent_zoom = 0x000800000,
    has_fullscreen_zoom = 0x001000000,
    has_ax_reference = 0x002000000,
    is_fullscreen = 0x004000000,
    is_visible = 0x008000000,
    is_minimized = 0x010000000,
    is_hidden = 0x020000000,
    is_floating = 0x040000000,
    is_sticky = 0x080000000,
    is_grabbed = 0x100000000,
};

/// Errors that can occur during window operations
pub const Error = error{
    InvalidElement,
    CannotComplete,
    AttributeUnsupported,
    ActionUnsupported,
    SkyLightError,
    OutOfMemory,
};

// ============================================================================
// Window operations using window ID (stateless)
// These don't require a Window struct, just the window ID
// ============================================================================

/// Get window frame via SkyLight
pub fn getFrame(wid: Id) Error!Rect {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var rect: c.CGRect = undefined;
    if (sl.SLSGetWindowBounds(cid, wid, &rect) != 0) return error.SkyLightError;
    return Rect.fromCG(rect);
}

/// Get window level
pub fn getLevel(wid: Id) Error!i32 {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var level: c_int = undefined;
    if (sl.SLSGetWindowLevel(cid, wid, &level) != 0) return error.SkyLightError;
    return @intCast(level);
}

/// Get window sub-level
pub fn getSubLevel(wid: Id) i32 {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();
    return @intCast(sl.SLSGetWindowSubLevel(cid, wid));
}

/// Get window opacity
pub fn getOpacity(wid: Id) Error!f32 {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var alpha: f32 = undefined;
    if (sl.SLSGetWindowAlpha(cid, wid, &alpha) != 0) return error.SkyLightError;
    return alpha;
}

/// Set window opacity
pub fn setOpacity(wid: Id, alpha: f32) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    if (sl.SLSSetWindowAlpha(cid, wid, alpha) != 0) return error.SkyLightError;
}

/// Set window level
pub fn setLevel(wid: Id, level: i32) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    if (sl.SLSSetWindowLevel(cid, wid, level) != 0) return error.SkyLightError;
}

/// Set window sub-level
pub fn setSubLevel(wid: Id, sub_level: i32) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    if (sl.SLSSetWindowSubLevel(cid, wid, sub_level) != 0) return error.SkyLightError;
}

/// Move window to point
pub fn move(wid: Id, point: Point) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var cg = point.toCG();
    if (sl.SLSMoveWindow(cid, wid, &cg) != 0) return error.SkyLightError;
}

/// Move window with its group
pub fn moveWithGroup(wid: Id, point: Point) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var cg = point.toCG();
    if (sl.SLSMoveWindowWithGroup(cid, wid, &cg) != 0) return error.SkyLightError;
}

/// Check if window has shadow
pub fn hasShadow(wid: Id) bool {
    const tags = getTags(wid);
    return (tags & 0x4) == 0; // Shadow disabled when bit 2 is set
}

/// Get window tags
pub fn getTags(wid: Id) u64 {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();

    // Use window iterator to get tags
    const query = sl.SLSWindowQueryWindows(cid, null, 0);
    if (query == null) return 0;
    defer c.c.CFRelease(query);

    const iter = sl.SLSWindowQueryResultCopyWindows(query);
    if (iter == null) return 0;
    defer c.c.CFRelease(iter);

    while (sl.SLSWindowIteratorAdvance(iter)) {
        if (sl.SLSWindowIteratorGetWindowID(iter) == wid) {
            return sl.SLSWindowIteratorGetTags(iter);
        }
    }
    return 0;
}

/// Check if window is sticky (on all spaces)
pub fn isSticky(wid: Id) bool {
    const tags = getTags(wid);
    return (tags & 0x2000) != 0;
}

/// Set window tags
pub fn setTags(wid: Id, tags: u64) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var t = tags;
    if (sl.SLSSetWindowTags(cid, wid, &t, 64) != 0) return error.SkyLightError;
}

/// Clear window tags
pub fn clearTags(wid: Id, tags: u64) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var t = tags;
    if (sl.SLSClearWindowTags(cid, wid, &t, 64) != 0) return error.SkyLightError;
}

/// Order window relative to another
pub fn order(wid: Id, ordering: c_int, relative_to: Id) Error!void {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    if (sl.SLSOrderWindow(cid, wid, ordering, relative_to) != 0) return error.SkyLightError;
}

/// Check if window is ordered in (visible)
pub fn isOrderedIn(wid: Id) bool {
    const sl = skylight.get() catch return false;
    const cid = sl.SLSMainConnectionID();
    var result: u8 = 0;
    if (sl.SLSWindowIsOrderedIn(cid, wid, &result) != 0) return false;
    return result != 0;
}

/// Get window owner connection ID
pub fn getOwner(wid: Id) Error!c_int {
    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();
    var owner: c_int = undefined;
    if (sl.SLSGetWindowOwner(cid, wid, &owner) != 0) return error.SkyLightError;
    return owner;
}

/// Get parent window ID
pub fn getParent(wid: Id) Id {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();

    const query = sl.SLSWindowQueryWindows(cid, null, 0);
    if (query == null) return 0;
    defer c.c.CFRelease(query);

    const iter = sl.SLSWindowQueryResultCopyWindows(query);
    if (iter == null) return 0;
    defer c.c.CFRelease(iter);

    while (sl.SLSWindowIteratorAdvance(iter)) {
        if (sl.SLSWindowIteratorGetWindowID(iter) == wid) {
            return sl.SLSWindowIteratorGetParentID(iter);
        }
    }
    return 0;
}

/// Get display UUID for window
pub fn getDisplayUUID(wid: Id) ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    const uuid = sl.SLSCopyManagedDisplayForWindow(cid, wid);
    return if (uuid != null) uuid else null;
}

/// Get space ID for window (returns first space if on multiple)
/// Falls back to display's current space if window-space query returns stale data
pub fn getSpace(wid: Id) u64 {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();

    // Create array with single window ID
    var wid_val = wid;
    const wid_num = c.c.CFNumberCreate(null, c.c.kCFNumberSInt32Type, &wid_val);
    if (wid_num == null) return getDisplaySpace(wid);
    defer c.c.CFRelease(wid_num);

    const wid_arr = c.c.CFArrayCreate(null, @ptrCast(@constCast(&wid_num)), 1, &c.c.kCFTypeArrayCallBacks);
    if (wid_arr == null) return getDisplaySpace(wid);
    defer c.c.CFRelease(wid_arr);

    const spaces = sl.SLSCopySpacesForWindows(cid, 0x7, wid_arr);
    if (spaces == null) return getDisplaySpace(wid);
    defer c.c.CFRelease(spaces);

    if (c.c.CFArrayGetCount(spaces) == 0) return getDisplaySpace(wid);

    const space_num: c.c.CFNumberRef = @ptrCast(c.c.CFArrayGetValueAtIndex(spaces, 0));
    var space_id: u64 = 0;
    _ = c.c.CFNumberGetValue(space_num, c.c.kCFNumberSInt64Type, &space_id);

    if (space_id == 0) return getDisplaySpace(wid);

    // Validate: check if the reported space is actually on the window's display
    // If not, the window was moved to the display's current space (display hotplug)
    const display_space = getDisplaySpace(wid);
    if (display_space != 0) {
        // Get display for the reported space
        const space_display_uuid = sl.SLSCopyManagedDisplayForSpace(cid, space_id);
        const window_display_uuid = sl.SLSCopyManagedDisplayForWindow(cid, wid);

        if (space_display_uuid != null and window_display_uuid != null) {
            defer c.c.CFRelease(space_display_uuid);
            defer c.c.CFRelease(window_display_uuid);

            // If the space's display doesn't match the window's display,
            // the window was moved to the current visible space on its display
            if (c.c.CFStringCompare(space_display_uuid, window_display_uuid, 0) != c.c.kCFCompareEqualTo) {
                return display_space;
            }
        } else {
            if (space_display_uuid) |uuid| c.c.CFRelease(uuid);
            if (window_display_uuid) |uuid| c.c.CFRelease(uuid);
        }
    }

    return space_id;
}

/// Get the current space of the display that contains this window
/// Used as fallback when SLSCopySpacesForWindows fails
pub fn getDisplaySpace(wid: Id) u64 {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();

    // Get display UUID for this window
    const uuid = sl.SLSCopyManagedDisplayForWindow(cid, wid);
    if (uuid == null) return 0;
    defer c.c.CFRelease(uuid);

    // Get current space on that display
    return sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
}

/// Get display UUID based on window's actual screen position (geometry-based)
/// This is more reliable than SLSCopyManagedDisplayForWindow after display hotplug
/// Returns null if unable to determine. Caller must CFRelease.
pub fn getDisplayByGeometry(wid: Id) ?c.CFStringRef {
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();

    // Get actual window bounds on screen
    var rect: c.CGRect = undefined;
    if (sl.SLSGetWindowBounds(cid, wid, &rect) != 0) return null;

    // Find which display this rect is on
    return sl.SLSCopyBestManagedDisplayForRect(cid, rect);
}

/// Get the current space based on window's actual screen position
/// More reliable than getDisplaySpace after display hotplug
pub fn getSpaceByGeometry(wid: Id) u64 {
    const sl = skylight.get() catch return 0;
    const cid = sl.SLSMainConnectionID();

    const uuid = getDisplayByGeometry(wid) orelse return 0;
    defer c.c.CFRelease(uuid);

    return sl.SLSManagedDisplayGetCurrentSpace(cid, uuid);
}

// ============================================================================
// AXUIElement operations (require element reference)
// ============================================================================

/// Get window frame via accessibility
pub fn getAXFrame(ref: c.AXUIElementRef) Error!Rect {
    const pos_val = accessibility.copyAttributeValue(ref, accessibility.Attr.position) catch return error.CannotComplete;
    defer c.c.CFRelease(pos_val);

    const size_val = accessibility.copyAttributeValue(ref, accessibility.Attr.size) catch return error.CannotComplete;
    defer c.c.CFRelease(size_val);

    const pos = accessibility.extractPoint(pos_val) orelse return error.CannotComplete;
    const size = accessibility.extractSize(size_val) orelse return error.CannotComplete;

    return Rect.init(pos.x, pos.y, size.width, size.height);
}

/// Get window origin via accessibility
pub fn getAXOrigin(ref: c.AXUIElementRef) Error!Point {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.position) catch return error.CannotComplete;
    defer c.c.CFRelease(val);
    return accessibility.extractPoint(val) orelse error.CannotComplete;
}

/// Set window position via accessibility
pub fn setAXPosition(ref: c.AXUIElementRef, point: Point) Error!void {
    const val = accessibility.createPointValue(point) orelse return error.CannotComplete;
    defer c.c.CFRelease(val);
    accessibility.setAttributeValue(ref, accessibility.Attr.position, val) catch return error.CannotComplete;
}

/// Set window size via accessibility
pub fn setAXSize(ref: c.AXUIElementRef, size: geometry.Size) Error!void {
    const val = accessibility.createSizeValue(size) orelse return error.CannotComplete;
    defer c.c.CFRelease(val);
    accessibility.setAttributeValue(ref, accessibility.Attr.size, val) catch return error.CannotComplete;
}

/// Get window role
pub fn getAXRole(ref: c.AXUIElementRef) ?c.CFStringRef {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.role) catch return null;
    return @ptrCast(val);
}

/// Get window subrole
pub fn getAXSubrole(ref: c.AXUIElementRef) ?c.CFStringRef {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.subrole) catch return null;
    return @ptrCast(val);
}

/// Get window title
pub fn getAXTitle(ref: c.AXUIElementRef) ?c.CFStringRef {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.title) catch return null;
    return @ptrCast(val);
}

/// Check if window is minimized
pub fn isAXMinimized(ref: c.AXUIElementRef) bool {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.minimized) catch return false;
    defer c.c.CFRelease(val);
    return accessibility.extractBool(val);
}

/// Check if window is fullscreen
pub fn isAXFullscreen(ref: c.AXUIElementRef) bool {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.fullscreen) catch return false;
    defer c.c.CFRelease(val);
    return accessibility.extractBool(val);
}

/// Check if window can move
pub fn canAXMove(ref: c.AXUIElementRef) bool {
    var value: c.c.Boolean = 0;
    const err = c.c.AXUIElementIsAttributeSettable(ref, @ptrCast(accessibility.Attr.position), &value);
    return err == c.c.kAXErrorSuccess and value != 0;
}

/// Check if window can resize
pub fn canAXResize(ref: c.AXUIElementRef) bool {
    var value: c.c.Boolean = 0;
    const err = c.c.AXUIElementIsAttributeSettable(ref, @ptrCast(accessibility.Attr.size), &value);
    return err == c.c.kAXErrorSuccess and value != 0;
}

/// Raise window
pub fn raise(ref: c.AXUIElementRef) Error!void {
    accessibility.performAction(ref, accessibility.Action.raise) catch return error.ActionUnsupported;
}

/// Set window frame (position and size) via accessibility
pub fn setAXFrame(ref: c.AXUIElementRef, frame: Rect) Error!void {
    // First move to a temporary position to break any window state lock
    setAXPosition(ref, Point{ .x = frame.x + 1, .y = frame.y + 1 }) catch {};

    // Resize → Move → Resize pattern
    // Due to macOS constraints, we may need to resize before AND after moving
    setAXSize(ref, geometry.Size{ .width = frame.width, .height = frame.height }) catch |e| {
        log.err("setAXSize failed: {}", .{e});
    };
    setAXPosition(ref, Point{ .x = frame.x, .y = frame.y }) catch |e| {
        log.err("setAXPosition failed: {}", .{e});
    };
    setAXSize(ref, geometry.Size{ .width = frame.width, .height = frame.height }) catch |e| {
        log.err("setAXSize (2nd) failed: {}", .{e});
    };
}

/// Check if app has enhanced user interface enabled
fn getEnhancedUserInterface(app_ref: c.AXUIElementRef) bool {
    const kAXEnhancedUserInterface = c.cfstr("AXEnhancedUserInterface");
    defer c.c.CFRelease(kAXEnhancedUserInterface);

    var value: c.CFTypeRef = null;
    if (c.c.AXUIElementCopyAttributeValue(app_ref, kAXEnhancedUserInterface, &value) == 0) {
        defer c.c.CFRelease(value);
        return c.c.CFBooleanGetValue(@ptrCast(value)) != 0;
    }
    return false;
}

/// Set enhanced user interface on app
fn setEnhancedUserInterface(app_ref: c.AXUIElementRef, enabled: bool) void {
    const kAXEnhancedUserInterface = c.cfstr("AXEnhancedUserInterface");
    defer c.c.CFRelease(kAXEnhancedUserInterface);

    const val: c.c.CFBooleanRef = if (enabled) c.c.kCFBooleanTrue else c.c.kCFBooleanFalse;
    _ = c.c.AXUIElementSetAttributeValue(app_ref, kAXEnhancedUserInterface, val);
}

/// Set window frame by window ID - finds the AXUIElement and sets position/size
/// This is the main entry point for tiling layout to apply window frames
pub fn setFrameById(wid: Id, frame: Rect) Error!void {
    log.debug("setFrameById: wid={} frame=({},{} {}x{})", .{ wid, frame.x, frame.y, frame.width, frame.height });

    const sl = skylight.get() catch return error.SkyLightError;
    const cid = sl.SLSMainConnectionID();

    // Get owner process
    var owner_cid: c_int = 0;
    if (sl.SLSGetWindowOwner(cid, wid, &owner_cid) != 0) return error.SkyLightError;

    var pid: c.pid_t = 0;
    _ = sl.SLSConnectionGetPID(owner_cid, &pid);
    if (pid == 0) return error.SkyLightError;

    // Create AX element for the application
    const app = c.c.AXUIElementCreateApplication(pid);
    if (app == null) return error.InvalidElement;
    defer c.c.CFRelease(app);

    // Get windows array
    var windows_ref: c.CFTypeRef = null;
    const kAXWindowsAttribute = c.cfstr("AXWindows");
    defer c.c.CFRelease(kAXWindowsAttribute);

    if (c.c.AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows_ref) != 0) {
        log.err("setFrameById: failed to get AXWindows for pid={}", .{pid});
        return error.CannotComplete;
    }
    defer c.c.CFRelease(windows_ref);

    const windows: c.c.CFArrayRef = @ptrCast(windows_ref);
    const count = c.c.CFArrayGetCount(windows);

    // Find window with matching ID
    var i: c.c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const win = c.c.CFArrayGetValueAtIndex(windows, i);
        const ax_win: c.AXUIElementRef = @ptrCast(@constCast(win));

        var win_id: u32 = 0;
        if (c._AXUIElementGetWindow(ax_win, &win_id) == 0 and win_id == wid) {
            // Log current frame before setting
            if (getAXFrame(ax_win)) |before| {
                log.debug("setFrameById: wid={} BEFORE=({},{} {}x{})", .{
                    wid, before.x, before.y, before.width, before.height,
                });
            } else |_| {}

            // Enhanced UI workaround: disable permanently to allow resize
            // Some apps (iTerm, etc.) use this and it interferes with programmatic resizing
            const eui = getEnhancedUserInterface(app);
            if (eui) {
                log.debug("setFrameById: wid={} disabling enhanced UI (permanently)", .{wid});
                setEnhancedUserInterface(app, false);
            }

            setAXFrame(ax_win, frame) catch {
                return error.CannotComplete;
            };

            // Small delay before verification to let the frame settle
            std.Thread.sleep(10 * std.time.ns_per_ms);

            // Verify frame was set - always log for debugging
            if (getAXFrame(ax_win)) |actual| {
                const x_ok = @as(i32, @intFromFloat(actual.x)) == @as(i32, @intFromFloat(frame.x));
                const w_ok = @as(i32, @intFromFloat(actual.width)) == @as(i32, @intFromFloat(frame.width));
                if (!x_ok or !w_ok) {
                    log.warn("setFrameById: wid={} MISMATCH wanted=({},{} {}x{}) got=({},{} {}x{})", .{
                        wid,
                        frame.x,
                        frame.y,
                        frame.width,
                        frame.height,
                        actual.x,
                        actual.y,
                        actual.width,
                        actual.height,
                    });
                    // Try again
                    setAXFrame(ax_win, frame) catch {};
                } else {
                    log.debug("setFrameById: wid={} OK at ({},{} {}x{})", .{
                        wid, actual.x, actual.y, actual.width, actual.height,
                    });
                }
            } else |_| {
                log.warn("setFrameById: wid={} could not verify frame", .{wid});
            }

            return;
        }
    }

    log.err("setFrameById: window {} not found in {} windows", .{ wid, count });
    return error.InvalidElement;
}

/// Check if this is a standard window (AXWindow role with AXStandardWindow subrole)
pub fn isStandardWindow(ref: c.AXUIElementRef) bool {
    const role = getAXRole(ref) orelse return false;
    defer c.c.CFRelease(@ptrCast(role));

    if (c.c.CFStringCompare(role, @ptrCast(accessibility.Role.window), 0) != c.c.kCFCompareEqualTo) {
        return false;
    }

    const subrole = getAXSubrole(ref);
    if (subrole == null) return false;
    defer c.c.CFRelease(@ptrCast(subrole.?));

    return c.c.CFStringCompare(subrole.?, @ptrCast(accessibility.Subrole.standard_window), 0) == c.c.kCFCompareEqualTo;
}

/// Check if window is a real manageable window
pub fn isReal(ref: c.AXUIElementRef) bool {
    const role = getAXRole(ref) orelse return false;
    defer c.c.CFRelease(@ptrCast(role));

    // Must be AXWindow
    if (c.c.CFStringCompare(role, @ptrCast(accessibility.Role.window), 0) != c.c.kCFCompareEqualTo) {
        return false;
    }

    const subrole = getAXSubrole(ref);
    if (subrole == null) return true; // Some apps don't set subrole

    defer c.c.CFRelease(@ptrCast(subrole.?));

    // Accept standard windows and dialogs
    const is_standard = c.c.CFStringCompare(subrole.?, @ptrCast(accessibility.Subrole.standard_window), 0) == c.c.kCFCompareEqualTo;
    const is_dialog = c.c.CFStringCompare(subrole.?, @ptrCast(accessibility.Subrole.dialog), 0) == c.c.kCFCompareEqualTo;

    return is_standard or is_dialog;
}

// ============================================================================
// Tests
// ============================================================================

test "Flags packed struct size" {
    // 9 bool flags = 9 bits, packed into 2 bytes
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Flags));
}

test "RuleFlags packed struct size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(RuleFlags));
}

test "NotificationMask packed struct size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(NotificationMask));
}

test "Flags default values" {
    const flags = Flags{};
    try std.testing.expect(flags.shadow);
    try std.testing.expect(!flags.fullscreen);
    try std.testing.expect(!flags.minimized);
    try std.testing.expect(!flags.floating);
    try std.testing.expect(!flags.sticky);
    try std.testing.expect(flags.movable);
    try std.testing.expect(flags.resizable);
}
