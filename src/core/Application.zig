const std = @import("std");
const c = @import("../platform/c.zig");
const accessibility = @import("../platform/accessibility.zig");
const runloop = @import("../platform/runloop.zig");

pub const Pid = c.pid_t;

/// Application notification subscriptions
pub const NotificationMask = packed struct {
    window_created: bool = false,
    window_focused: bool = false,
    window_moved: bool = false,
    window_resized: bool = false,
    title_changed: bool = false,
    menu_opened: bool = false,
    menu_closed: bool = false,
    _padding: u1 = 0,
};

/// Errors that can occur during application operations
pub const Error = error{
    InvalidElement,
    CannotComplete,
    AttributeUnsupported,
    ObserverCreationFailed,
    NotificationFailed,
};

// ============================================================================
// Application operations using PID (stateless)
// ============================================================================

/// Create application accessibility element. Caller must CFRelease.
pub fn createElement(pid: Pid) c.AXUIElementRef {
    return accessibility.createApplicationElement(pid);
}

/// Check if application is frontmost
pub fn isFrontmost(ref: c.AXUIElementRef) bool {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.frontmost) catch return false;
    defer c.c.CFRelease(val);
    return accessibility.extractBool(val);
}

/// Check if application is hidden
pub fn isHidden(ref: c.AXUIElementRef) bool {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.hidden) catch return false;
    defer c.c.CFRelease(val);
    return accessibility.extractBool(val);
}

/// Get main window AXUIElementRef. Caller must CFRelease.
pub fn getMainWindow(ref: c.AXUIElementRef) ?c.AXUIElementRef {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.main_window) catch return null;
    return @ptrCast(val);
}

/// Get focused window AXUIElementRef. Caller must CFRelease.
pub fn getFocusedWindow(ref: c.AXUIElementRef) c.AXUIElementRef {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.focused_window) catch return null;
    const ptr: *const anyopaque = val orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Get window list as CFArray. Caller must CFRelease.
pub fn getWindowList(ref: c.AXUIElementRef) c.CFArrayRef {
    const val = accessibility.copyAttributeValue(ref, accessibility.Attr.windows) catch return null;
    // CFTypeRef is ?*const anyopaque, CFArrayRef is ?*const __CFArray
    const opaque_ptr = val orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

/// Get window ID from AXUIElementRef
pub fn getWindowId(window_ref: c.AXUIElementRef) ?u32 {
    var wid: u32 = 0;
    if (c._AXUIElementGetWindow(window_ref, &wid) != c.c.kAXErrorSuccess) {
        return null;
    }
    return if (wid != 0) wid else null;
}

// ============================================================================
// Observer management
// ============================================================================

/// Create and configure an observer for application events
pub fn createObserver(pid: Pid, callback: accessibility.ObserverCallback) Error!c.c.AXObserverRef {
    return accessibility.createObserver(pid, callback) catch return error.ObserverCreationFailed;
}

/// Subscribe observer to window created notifications
pub fn observeWindowCreated(observer: c.c.AXObserverRef, app_ref: c.AXUIElementRef, context: ?*anyopaque) Error!void {
    accessibility.observerAddNotification(observer, app_ref, accessibility.Notification.window_created, context) catch return error.NotificationFailed;
}

/// Subscribe observer to focused window changed notifications
pub fn observeFocusedWindowChanged(observer: c.c.AXObserverRef, app_ref: c.AXUIElementRef, context: ?*anyopaque) Error!void {
    accessibility.observerAddNotification(observer, app_ref, accessibility.Notification.focused_window_changed, context) catch return error.NotificationFailed;
}

/// Subscribe observer to window moved notifications
pub fn observeWindowMoved(observer: c.c.AXObserverRef, app_ref: c.AXUIElementRef, context: ?*anyopaque) Error!void {
    accessibility.observerAddNotification(observer, app_ref, accessibility.Notification.window_moved, context) catch return error.NotificationFailed;
}

/// Subscribe observer to window resized notifications
pub fn observeWindowResized(observer: c.c.AXObserverRef, app_ref: c.AXUIElementRef, context: ?*anyopaque) Error!void {
    accessibility.observerAddNotification(observer, app_ref, accessibility.Notification.window_resized, context) catch return error.NotificationFailed;
}

/// Subscribe observer to title changed notifications
pub fn observeTitleChanged(observer: c.c.AXObserverRef, app_ref: c.AXUIElementRef, context: ?*anyopaque) Error!void {
    accessibility.observerAddNotification(observer, app_ref, accessibility.Notification.title_changed, context) catch return error.NotificationFailed;
}

/// Add observer to run loop
pub fn addObserverToRunLoop(observer: c.c.AXObserverRef) void {
    runloop.addAXObserver(observer);
}

/// Remove observer from run loop
pub fn removeObserverFromRunLoop(observer: c.c.AXObserverRef) void {
    runloop.removeAXObserver(observer);
}

/// Remove notification from observer
pub fn removeNotification(observer: c.c.AXObserverRef, element: c.AXUIElementRef, notification: c.CFStringRef) void {
    accessibility.observerRemoveNotification(observer, element, notification);
}

/// Subscribe to all standard application notifications
pub fn observeAll(observer: c.c.AXObserverRef, app_ref: c.AXUIElementRef, context: ?*anyopaque) Error!void {
    try observeWindowCreated(observer, app_ref, context);
    try observeFocusedWindowChanged(observer, app_ref, context);
    try observeWindowMoved(observer, app_ref, context);
    try observeWindowResized(observer, app_ref, context);
    try observeTitleChanged(observer, app_ref, context);
}

// ============================================================================
// Connection management (for SkyLight)
// ============================================================================

/// Get PSN to SkyLight connection mapping
pub fn getConnection(psn: *c.c.ProcessSerialNumber) ?c_int {
    const skylight = @import("../platform/skylight.zig");
    const sl = skylight.get() catch return null;
    const cid = sl.SLSMainConnectionID();
    var conn: c_int = undefined;
    if (sl.SLSGetConnectionIDForPSN(cid, psn, &conn) != 0) return null;
    return conn;
}

/// Get PID from connection
pub fn getPidFromConnection(conn: c_int) ?Pid {
    const skylight = @import("../platform/skylight.zig");
    const sl = skylight.get() catch return null;
    var pid: Pid = undefined;
    if (sl.SLSConnectionGetPID(conn, &pid) != 0) return null;
    return pid;
}

/// Get PSN from connection
pub fn getPsnFromConnection(conn: c_int) ?c.c.ProcessSerialNumber {
    const skylight = @import("../platform/skylight.zig");
    const sl = skylight.get() catch return null;
    var psn: c.c.ProcessSerialNumber = undefined;
    if (sl.SLSGetConnectionPSN(conn, &psn) != 0) return null;
    return psn;
}

// ============================================================================
// Tests
// ============================================================================

test "NotificationMask packed struct size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(NotificationMask));
}

test "NotificationMask default values" {
    const mask = NotificationMask{};
    try std.testing.expect(!mask.window_created);
    try std.testing.expect(!mask.window_focused);
    try std.testing.expect(!mask.window_moved);
    try std.testing.expect(!mask.window_resized);
    try std.testing.expect(!mask.title_changed);
}
