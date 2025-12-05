const std = @import("std");
const c = @import("../platform/c.zig");
const geometry = @import("../core/geometry.zig");

const Point = geometry.Point;
const Rect = geometry.Rect;

/// AXUIElement errors mapped from AXError codes
pub const Error = error{
    Failure,
    IllegalArgument,
    InvalidElement,
    InvalidObserver,
    CannotComplete,
    AttributeUnsupported,
    ActionUnsupported,
    NotificationUnsupported,
    NotImplemented,
    NotificationAlreadyRegistered,
    NotificationNotRegistered,
    APIDisabled,
    NoValue,
    ParameterizedAttributeUnsupported,
    NotEnoughPrecision,
};

pub fn mapError(err: c.AXError) Error {
    return switch (err) {
        c.c.kAXErrorFailure => error.Failure,
        c.c.kAXErrorIllegalArgument => error.IllegalArgument,
        c.c.kAXErrorInvalidUIElement => error.InvalidElement,
        c.c.kAXErrorInvalidUIElementObserver => error.InvalidObserver,
        c.c.kAXErrorCannotComplete => error.CannotComplete,
        c.c.kAXErrorAttributeUnsupported => error.AttributeUnsupported,
        c.c.kAXErrorActionUnsupported => error.ActionUnsupported,
        c.c.kAXErrorNotificationUnsupported => error.NotificationUnsupported,
        c.c.kAXErrorNotImplemented => error.NotImplemented,
        c.c.kAXErrorNotificationAlreadyRegistered => error.NotificationAlreadyRegistered,
        c.c.kAXErrorNotificationNotRegistered => error.NotificationNotRegistered,
        c.c.kAXErrorAPIDisabled => error.APIDisabled,
        c.c.kAXErrorNoValue => error.NoValue,
        c.c.kAXErrorParameterizedAttributeUnsupported => error.ParameterizedAttributeUnsupported,
        c.c.kAXErrorNotEnoughPrecision => error.NotEnoughPrecision,
        else => error.Failure,
    };
}

// ============================================================================
// Low-level AXUIElement operations
// These are thin wrappers - caller manages memory and lifetime
// ============================================================================

/// Create application element from PID. Caller must release with CFRelease.
pub fn createApplicationElement(pid: c.pid_t) c.AXUIElementRef {
    return c.c.AXUIElementCreateApplication(pid);
}

/// Create system-wide element. Caller must release with CFRelease.
pub fn createSystemWideElement() c.AXUIElementRef {
    return c.c.AXUIElementCreateSystemWide();
}

/// Get PID from element
pub fn getPid(ref: c.AXUIElementRef) Error!c.pid_t {
    var pid: c.pid_t = undefined;
    const err = c.c.AXUIElementGetPid(ref, &pid);
    if (err != c.c.kAXErrorSuccess) return mapError(err);
    return pid;
}

/// Copy attribute value. Caller must CFRelease the returned value.
pub fn copyAttributeValue(ref: c.AXUIElementRef, attr: [*:0]const u8) Error!c.CFTypeRef {
    var value: c.CFTypeRef = undefined;
    // Create CFString from C string for the attribute name
    const attr_str = c.c.CFStringCreateWithCString(null, attr, c.c.kCFStringEncodingUTF8);
    if (attr_str == null) return error.Failure;
    defer c.c.CFRelease(attr_str);

    const err = c.c.AXUIElementCopyAttributeValue(ref, attr_str, &value);
    if (err != c.c.kAXErrorSuccess) return mapError(err);
    return value;
}

/// Set attribute value
pub fn setAttributeValue(ref: c.AXUIElementRef, attr: [*:0]const u8, value: c.CFTypeRef) Error!void {
    const attr_str = c.c.CFStringCreateWithCString(null, attr, c.c.kCFStringEncodingUTF8);
    if (attr_str == null) return error.Failure;
    defer c.c.CFRelease(attr_str);

    const err = c.c.AXUIElementSetAttributeValue(ref, attr_str, value);
    if (err != c.c.kAXErrorSuccess) return mapError(err);
}

/// Perform action
pub fn performAction(ref: c.AXUIElementRef, action: [*:0]const u8) Error!void {
    const action_str = c.c.CFStringCreateWithCString(null, action, c.c.kCFStringEncodingUTF8);
    if (action_str == null) return error.Failure;
    defer c.c.CFRelease(action_str);

    const err = c.c.AXUIElementPerformAction(ref, action_str);
    if (err != c.c.kAXErrorSuccess) return mapError(err);
}

// ============================================================================
// Value extraction helpers
// ============================================================================

/// Extract CGPoint from AXValue
pub fn extractPoint(value: c.CFTypeRef) ?Point {
    var point: c.CGPoint = undefined;
    if (c.c.AXValueGetValue(@ptrCast(value), c.c.kAXValueCGPointType, &point) == 0) {
        return null;
    }
    return Point.fromCG(point);
}

/// Extract CGSize from AXValue
pub fn extractSize(value: c.CFTypeRef) ?geometry.Size {
    var size: c.c.CGSize = undefined;
    if (c.c.AXValueGetValue(@ptrCast(value), c.c.kAXValueCGSizeType, &size) == 0) {
        return null;
    }
    return geometry.Size.fromCG(size);
}

/// Extract boolean from CFBoolean
pub fn extractBool(value: c.CFTypeRef) bool {
    return c.c.CFBooleanGetValue(@ptrCast(value)) != 0;
}

/// Create AXValue from CGPoint. Caller must CFRelease.
pub fn createPointValue(point: Point) ?c.CFTypeRef {
    var cg = point.toCG();
    const maybe_result = c.c.AXValueCreate(c.c.kAXValueCGPointType, &cg);
    const result = maybe_result orelse return null;
    return result;
}

/// Create AXValue from CGSize. Caller must CFRelease.
pub fn createSizeValue(size: geometry.Size) ?c.CFTypeRef {
    var cg = size.toCG();
    const maybe_result = c.c.AXValueCreate(c.c.kAXValueCGSizeType, &cg);
    const result = maybe_result orelse return null;
    return result;
}

/// Compare a CFStringRef with a C string
pub fn cfStringEquals(cf_str: c.CFStringRef, c_str: [*:0]const u8) bool {
    const compare_str = c.c.CFStringCreateWithCString(null, c_str, c.c.kCFStringEncodingUTF8);
    if (compare_str == null) return false;
    defer c.c.CFRelease(compare_str);
    return c.c.CFStringCompare(cf_str, compare_str, 0) == c.c.kCFCompareEqualTo;
}

// ============================================================================
// Common attribute names
// ============================================================================

pub const Attr = struct {
    pub const position: [*:0]const u8 = "AXPosition";
    pub const size: [*:0]const u8 = "AXSize";
    pub const title: [*:0]const u8 = "AXTitle";
    pub const role: [*:0]const u8 = "AXRole";
    pub const subrole: [*:0]const u8 = "AXSubrole";
    pub const minimized: [*:0]const u8 = "AXMinimized";
    pub const fullscreen: [*:0]const u8 = "AXFullScreen";
    pub const focused: [*:0]const u8 = "AXFocused";
    pub const windows: [*:0]const u8 = "AXWindows";
    pub const focused_window: [*:0]const u8 = "AXFocusedWindow";
    pub const main_window: [*:0]const u8 = "AXMainWindow";
    pub const hidden: [*:0]const u8 = "AXHidden";
    pub const frontmost: [*:0]const u8 = "AXFrontmost";
};

pub const Action = struct {
    pub const raise: [*:0]const u8 = "AXRaise";
    pub const press: [*:0]const u8 = "AXPress";
};

pub const Role = struct {
    pub const window: [*:0]const u8 = "AXWindow";
    pub const application: [*:0]const u8 = "AXApplication";
    pub const sheet: [*:0]const u8 = "AXSheet";
    pub const drawer: [*:0]const u8 = "AXDrawer";
};

pub const Subrole = struct {
    pub const standard_window: [*:0]const u8 = "AXStandardWindow";
    pub const dialog: [*:0]const u8 = "AXDialog";
    pub const system_dialog: [*:0]const u8 = "AXSystemDialog";
    pub const floating_window: [*:0]const u8 = "AXFloatingWindow";
};

// ============================================================================
// Observer (for notifications)
// ============================================================================

pub const ObserverCallback = *const fn (
    observer: c.c.AXObserverRef,
    element: c.AXUIElementRef,
    notification: c.CFStringRef,
    context: ?*anyopaque,
) callconv(.c) void;

/// Create observer for a PID. Caller must CFRelease.
pub fn createObserver(pid: c.pid_t, callback: ObserverCallback) Error!c.c.AXObserverRef {
    var observer: c.c.AXObserverRef = undefined;
    const err = c.c.AXObserverCreate(pid, callback, &observer);
    if (err != c.c.kAXErrorSuccess) return mapError(err);
    return observer;
}

/// Add notification to observer
pub fn observerAddNotification(
    observer: c.c.AXObserverRef,
    element: c.AXUIElementRef,
    notification_name: [*:0]const u8,
    context: ?*anyopaque,
) Error!void {
    const notification = createCFString(notification_name);
    defer c.c.CFRelease(notification);
    const err = c.c.AXObserverAddNotification(observer, element, notification, context);
    if (err != c.c.kAXErrorSuccess) return mapError(err);
}

/// Remove notification from observer
pub fn observerRemoveNotification(
    observer: c.c.AXObserverRef,
    element: c.AXUIElementRef,
    notification_name: [*:0]const u8,
) void {
    const notification = createCFString(notification_name);
    defer c.c.CFRelease(notification);
    _ = c.c.AXObserverRemoveNotification(observer, element, notification);
}

/// Get run loop source from observer
pub fn observerGetRunLoopSource(observer: c.c.AXObserverRef) c.c.CFRunLoopSourceRef {
    return c.c.AXObserverGetRunLoopSource(observer);
}

// ============================================================================
// Notification constants
// ============================================================================

/// Create a CFStringRef from a C string at runtime
pub fn createCFString(s: [*:0]const u8) c.CFStringRef {
    return c.c.CFStringCreateWithCString(null, s, c.c.kCFStringEncodingUTF8);
}

pub const Notification = struct {
    // Application notifications - these strings match the AXNotification constants
    pub const window_created: [*:0]const u8 = "AXCreated";
    pub const focused_window_changed: [*:0]const u8 = "AXFocusedWindowChanged";
    pub const window_moved: [*:0]const u8 = "AXWindowMoved";
    pub const window_resized: [*:0]const u8 = "AXWindowResized";
    pub const title_changed: [*:0]const u8 = "AXTitleChanged";
    pub const menu_opened: [*:0]const u8 = "AXMenuOpened";
    pub const menu_closed: [*:0]const u8 = "AXMenuClosed";

    // Window notifications
    pub const element_destroyed: [*:0]const u8 = "AXUIElementDestroyed";
    pub const window_minimized: [*:0]const u8 = "AXWindowMiniaturized";
    pub const window_deminimized: [*:0]const u8 = "AXWindowDeminiaturized";
};

// ============================================================================
// Utility
// ============================================================================

/// Check if accessibility API is trusted/enabled
pub fn isProcessTrusted() bool {
    return c.c.AXIsProcessTrusted() != 0;
}

/// Check if accessibility API is trusted, with prompt option
pub fn isProcessTrustedWithOptions(prompt: bool) bool {
    if (!prompt) return isProcessTrusted();

    const key = c.c.kAXTrustedCheckOptionPrompt;
    var value: c.CFTypeRef = if (prompt) c.c.kCFBooleanTrue else c.c.kCFBooleanFalse;
    const options = c.c.CFDictionaryCreate(
        null,
        @ptrCast(@constCast(&key)),
        @ptrCast(&value),
        1,
        &c.c.kCFTypeDictionaryKeyCallBacks,
        &c.c.kCFTypeDictionaryValueCallBacks,
    );
    defer c.c.CFRelease(options);

    return c.c.AXIsProcessTrustedWithOptions(options) != 0;
}

// ============================================================================
// CFString helpers
// ============================================================================

/// Copy CFString to Zig slice. Caller owns returned memory.
pub fn cfStringToSlice(allocator: std.mem.Allocator, cf_string: c.CFStringRef) ![]const u8 {
    const length = c.c.CFStringGetLength(cf_string);
    if (length == 0) return "";

    const max_size: usize = @intCast(c.c.CFStringGetMaximumSizeForEncoding(length, c.c.kCFStringEncodingUTF8) + 1);
    const buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    if (c.c.CFStringGetCString(cf_string, buffer.ptr, @intCast(max_size), c.c.kCFStringEncodingUTF8) == 0) {
        allocator.free(buffer);
        return error.Failure;
    }

    const actual_len = std.mem.indexOfScalar(u8, buffer, 0) orelse max_size;
    // Shrink to actual size if possible
    if (allocator.resize(buffer, actual_len)) |resized| {
        return resized;
    }
    return buffer[0..actual_len];
}

// ============================================================================
// Tests
// ============================================================================

test "createSystemWideElement returns non-null" {
    const elem = createSystemWideElement();
    defer c.c.CFRelease(elem);
    try std.testing.expect(elem != null);
}

test "createApplicationElement returns non-null" {
    const elem = createApplicationElement(1); // launchd
    defer c.c.CFRelease(elem);
    try std.testing.expect(elem != null);
}

test "Attr constants are valid" {
    try std.testing.expectEqualStrings("AXPosition", std.mem.span(Attr.position));
    try std.testing.expectEqualStrings("AXTitle", std.mem.span(Attr.title));
}
