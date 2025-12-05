const std = @import("std");
const c = @import("../platform/c.zig");
const Event = @import("../events/Event.zig").Event;

const log = std.log.scoped(.workspace);

/// Callback type for workspace events
pub const EventCallback = *const fn (Event) void;

/// WorkspaceObserver subscribes to NSWorkspace notifications and delivers events
/// through a callback. Uses Objective-C runtime to dynamically create an observer class.
pub const WorkspaceObserver = struct {
    observer: c.c.id,
    callback: EventCallback,
    subscriptions: u32 = 0, // Number of successful notification subscriptions

    const Self = @This();

    // Objective-C class registered at runtime
    var observer_class: c.c.Class = null;

    /// Initialize and start observing workspace notifications
    pub fn init(callback: EventCallback) !Self {
        // Register our observer class if not already done
        if (observer_class == null) {
            observer_class = registerObserverClass() orelse {
                log.err("failed to register observer class", .{});
                return error.ClassRegistration;
            };
        }

        // Allocate and init the observer
        const alloced = msgSendId0(classAsId(observer_class.?), sel("alloc"));
        if (alloced == null) return error.AllocationFailed;

        const observer = msgSendId0(alloced, sel("init"));
        if (observer == null) return error.InitFailed;

        // Store callback in associated object
        setCallback(observer, callback);

        // Subscribe to notifications
        const subscriptions = subscribeToNotifications(observer);

        if (subscriptions == 0) {
            log.err("workspace observer: no notifications subscribed - events will not be received", .{});
            // Don't fail - observer is valid, just won't receive notifications
        } else if (subscriptions < 8) {
            log.warn("workspace observer: only {d}/11 notifications subscribed", .{subscriptions});
        }

        log.info("workspace observer initialized ({d} subscriptions)", .{subscriptions});

        return Self{
            .observer = observer,
            .callback = callback,
            .subscriptions = subscriptions,
        };
    }

    /// Check if the observer is healthy (has subscriptions)
    pub fn isHealthy(self: *const Self) bool {
        return self.observer != null and self.subscriptions > 0;
    }

    pub fn deinit(self: *Self) void {
        if (self.observer != null) {
            unsubscribeFromNotifications(self.observer);
            msgSendVoid0(self.observer, sel("release"));
            self.observer = null;
        }
    }

    // =========================================================================
    // Objective-C runtime internals
    // =========================================================================

    fn registerObserverClass() ?c.c.Class {
        const superclass = c.c.objc_getClass("NSObject");
        if (superclass == null) return null;

        const class = c.c.objc_allocateClassPair(superclass, "YabaiWorkspaceObserver", 0);
        if (class == null) return null;

        // Add notification handler methods
        _ = c.c.class_addMethod(class, sel("spaceChanged:"), @ptrCast(&onSpaceChanged), "v@:@");
        _ = c.c.class_addMethod(class, sel("displayChanged:"), @ptrCast(&onDisplayChanged), "v@:@");
        _ = c.c.class_addMethod(class, sel("didLaunchApp:"), @ptrCast(&onAppLaunched), "v@:@");
        _ = c.c.class_addMethod(class, sel("didTerminateApp:"), @ptrCast(&onAppTerminated), "v@:@");
        _ = c.c.class_addMethod(class, sel("didHideApp:"), @ptrCast(&onAppHidden), "v@:@");
        _ = c.c.class_addMethod(class, sel("didUnhideApp:"), @ptrCast(&onAppVisible), "v@:@");
        _ = c.c.class_addMethod(class, sel("didActivateApp:"), @ptrCast(&onAppActivated), "v@:@");
        _ = c.c.class_addMethod(class, sel("didWake:"), @ptrCast(&onSystemWoke), "v@:@");
        _ = c.c.class_addMethod(class, sel("menuBarChanged:"), @ptrCast(&onMenuBarChanged), "v@:@");
        _ = c.c.class_addMethod(class, sel("dockRestarted:"), @ptrCast(&onDockRestarted), "v@:@");
        _ = c.c.class_addMethod(class, sel("dockPrefChanged:"), @ptrCast(&onDockPrefChanged), "v@:@");

        c.c.objc_registerClassPair(class);

        return class;
    }

    fn subscribeToNotifications(observer: c.c.id) u32 {
        var count: u32 = 0;

        const NSWorkspace = c.c.objc_getClass("NSWorkspace") orelse return 0;
        const sharedWorkspace = msgSendId0(classAsId(NSWorkspace), sel("sharedWorkspace"));
        if (sharedWorkspace == null) return 0;

        const notificationCenter = msgSendId0(sharedWorkspace, sel("notificationCenter"));
        if (notificationCenter == null) return 0;

        // Space changed
        if (addNotification(notificationCenter, observer, "spaceChanged:", "NSWorkspaceActiveSpaceDidChangeNotification")) count += 1;

        // Display changed
        if (addNotification(notificationCenter, observer, "displayChanged:", "NSWorkspaceActiveDisplayDidChangeNotification")) count += 1;

        // App hidden/unhidden
        if (addNotification(notificationCenter, observer, "didHideApp:", "NSWorkspaceDidHideApplicationNotification")) count += 1;
        if (addNotification(notificationCenter, observer, "didUnhideApp:", "NSWorkspaceDidUnhideApplicationNotification")) count += 1;

        // App launched/terminated
        if (addNotification(notificationCenter, observer, "didLaunchApp:", "NSWorkspaceDidLaunchApplicationNotification")) count += 1;
        if (addNotification(notificationCenter, observer, "didTerminateApp:", "NSWorkspaceDidTerminateApplicationNotification")) count += 1;

        // App activated (front switched)
        if (addNotification(notificationCenter, observer, "didActivateApp:", "NSWorkspaceDidActivateApplicationNotification")) count += 1;

        // System wake
        if (addNotification(notificationCenter, observer, "didWake:", "NSWorkspaceDidWakeNotification")) count += 1;

        // Distributed notifications (menu bar, dock)
        const NSDistributedNotificationCenter = c.c.objc_getClass("NSDistributedNotificationCenter");
        if (NSDistributedNotificationCenter) |distClass| {
            const distCenter = msgSendId0(classAsId(distClass), sel("defaultCenter"));
            if (distCenter != null) {
                if (addNotification(distCenter, observer, "menuBarChanged:", "AppleInterfaceMenuBarHidingChangedNotification")) count += 1;
                if (addNotification(distCenter, observer, "dockPrefChanged:", "com.apple.dock.prefchanged")) count += 1;
            }
        }

        // Default notification center (dock restart)
        const NSNotificationCenter = c.c.objc_getClass("NSNotificationCenter");
        if (NSNotificationCenter) |notifClass| {
            const defaultCenter = msgSendId0(classAsId(notifClass), sel("defaultCenter"));
            if (defaultCenter != null) {
                if (addNotification(defaultCenter, observer, "dockRestarted:", "NSApplicationDockDidRestartNotification")) count += 1;
            }
        }

        return count;
    }

    fn addNotification(center: c.c.id, observer: c.c.id, handler: [*:0]const u8, name: [*:0]const u8) bool {
        const NSString = c.c.objc_getClass("NSString") orelse return false;
        const notifName = msgSendIdCStr(classAsId(NSString), sel("stringWithUTF8String:"), name);
        if (notifName == null) return false;

        msgSendAddObserver(center, sel("addObserver:selector:name:object:"), observer, sel(handler), notifName, null);
        return true;
    }

    fn unsubscribeFromNotifications(observer: c.c.id) void {
        const NSWorkspace = c.c.objc_getClass("NSWorkspace") orelse return;
        const sharedWorkspace = msgSendId0(classAsId(NSWorkspace), sel("sharedWorkspace"));
        if (sharedWorkspace == null) return;

        const notificationCenter = msgSendId0(sharedWorkspace, sel("notificationCenter"));
        if (notificationCenter != null) {
            msgSendRemoveObserver(notificationCenter, sel("removeObserver:"), observer);
        }

        const NSDistributedNotificationCenter = c.c.objc_getClass("NSDistributedNotificationCenter") orelse return;
        const distCenter = msgSendId0(classAsId(NSDistributedNotificationCenter), sel("defaultCenter"));
        if (distCenter != null) {
            msgSendRemoveObserver(distCenter, sel("removeObserver:"), observer);
        }

        const NSNotificationCenter = c.c.objc_getClass("NSNotificationCenter") orelse return;
        const defaultCenter = msgSendId0(classAsId(NSNotificationCenter), sel("defaultCenter"));
        if (defaultCenter != null) {
            msgSendRemoveObserver(defaultCenter, sel("removeObserver:"), observer);
        }
    }

    // =========================================================================
    // Callback storage - simple global since we only have one observer
    // =========================================================================

    var global_callback: ?EventCallback = null;

    fn setCallback(_: c.c.id, callback: EventCallback) void {
        global_callback = callback;
    }

    fn getCallback(_: c.c.id) ?EventCallback {
        return global_callback;
    }

    // =========================================================================
    // Notification handlers (called from Objective-C runtime)
    // =========================================================================

    fn onSpaceChanged(self: c.c.id, _: c.c.SEL, _: c.c.id) callconv(.c) void {
        if (getCallback(self)) |cb| {
            cb(.{ .space_changed = .{ .space_id = 0, .display_id = null } });
        }
    }

    fn onDisplayChanged(self: c.c.id, _: c.c.SEL, _: c.c.id) callconv(.c) void {
        if (getCallback(self)) |cb| {
            cb(.{ .display_changed = .{ .display_id = 0 } });
        }
    }

    fn onAppHidden(self: c.c.id, _: c.c.SEL, notification: c.c.id) callconv(.c) void {
        const pid = extractPidFromNotification(notification);
        if (getCallback(self)) |cb| {
            cb(.{ .application_hidden = .{ .pid = pid } });
        }
    }

    fn onAppVisible(self: c.c.id, _: c.c.SEL, notification: c.c.id) callconv(.c) void {
        const pid = extractPidFromNotification(notification);
        if (getCallback(self)) |cb| {
            cb(.{ .application_visible = .{ .pid = pid } });
        }
    }

    fn onAppLaunched(self: c.c.id, _: c.c.SEL, notification: c.c.id) callconv(.c) void {
        const pid = extractPidFromNotification(notification);
        if (pid > 0) {
            if (getCallback(self)) |cb| {
                cb(.{ .application_launched = .{ .pid = pid } });
            }
        }
    }

    fn onAppTerminated(self: c.c.id, _: c.c.SEL, notification: c.c.id) callconv(.c) void {
        const pid = extractPidFromNotification(notification);
        if (pid > 0) {
            if (getCallback(self)) |cb| {
                cb(.{ .application_terminated = .{ .pid = pid } });
            }
        }
    }

    fn onAppActivated(self: c.c.id, _: c.c.SEL, notification: c.c.id) callconv(.c) void {
        const pid = extractPidFromNotification(notification);
        if (pid > 0) {
            if (getCallback(self)) |cb| {
                cb(.{ .application_front_switched = .{ .pid = pid } });
            }
        }
    }

    fn onSystemWoke(self: c.c.id, _: c.c.SEL, _: c.c.id) callconv(.c) void {
        if (getCallback(self)) |cb| {
            cb(.system_woke);
        }
    }

    fn onMenuBarChanged(self: c.c.id, _: c.c.SEL, _: c.c.id) callconv(.c) void {
        if (getCallback(self)) |cb| {
            cb(.menu_bar_hidden_changed);
        }
    }

    fn onDockRestarted(self: c.c.id, _: c.c.SEL, _: c.c.id) callconv(.c) void {
        if (getCallback(self)) |cb| {
            cb(.dock_did_restart);
        }
    }

    fn onDockPrefChanged(self: c.c.id, _: c.c.SEL, _: c.c.id) callconv(.c) void {
        if (getCallback(self)) |cb| {
            cb(.dock_did_change_pref);
        }
    }

    fn extractPidFromNotification(notification: c.c.id) c.pid_t {
        if (notification == null) return 0;

        const userInfo = msgSendId0(notification, sel("userInfo"));
        if (userInfo == null) return 0;

        const NSString = c.c.objc_getClass("NSString") orelse return 0;
        const key = msgSendIdCStr(classAsId(NSString), sel("stringWithUTF8String:"), "NSWorkspaceApplicationKey");
        if (key == null) return 0;

        const app = msgSendId1(userInfo, sel("objectForKey:"), key);
        if (app == null) return 0;

        return msgSendPid(app, sel("processIdentifier"));
    }
};

// =============================================================================
// objc_msgSend wrappers - use explicit signatures to avoid varargs issues
// =============================================================================

extern fn objc_msgSend() callconv(.c) void;

/// Selector helper
inline fn sel(name: [*:0]const u8) c.c.SEL {
    return c.c.sel_registerName(name);
}

/// Basic message send with no arguments, returns id
fn msgSendId0(target: c.c.id, s: c.c.SEL) c.c.id {
    const Fn = *const fn (c.c.id, c.c.SEL) callconv(.c) c.c.id;
    const send: Fn = @ptrCast(&objc_msgSend);
    return send(target, s);
}

/// Message send with one id argument, returns id
fn msgSendId1(target: c.c.id, s: c.c.SEL, arg: c.c.id) c.c.id {
    const Fn = *const fn (c.c.id, c.c.SEL, c.c.id) callconv(.c) c.c.id;
    const send: Fn = @ptrCast(&objc_msgSend);
    return send(target, s, arg);
}

/// Message send with C string argument, returns id
fn msgSendIdCStr(target: c.c.id, s: c.c.SEL, arg: [*:0]const u8) c.c.id {
    const Fn = *const fn (c.c.id, c.c.SEL, [*:0]const u8) callconv(.c) c.c.id;
    const send: Fn = @ptrCast(&objc_msgSend);
    return send(target, s, arg);
}

/// Message send for addObserver:selector:name:object:
fn msgSendAddObserver(target: c.c.id, s: c.c.SEL, observer: c.c.id, handler_sel: c.c.SEL, name: c.c.id, object: c.c.id) void {
    const Fn = *const fn (c.c.id, c.c.SEL, c.c.id, c.c.SEL, c.c.id, c.c.id) callconv(.c) void;
    const send: Fn = @ptrCast(&objc_msgSend);
    send(target, s, observer, handler_sel, name, object);
}

/// Message send for removeObserver:
fn msgSendRemoveObserver(target: c.c.id, s: c.c.SEL, observer: c.c.id) void {
    const Fn = *const fn (c.c.id, c.c.SEL, c.c.id) callconv(.c) void;
    const send: Fn = @ptrCast(&objc_msgSend);
    send(target, s, observer);
}

/// Message send returning pid_t (int32)
fn msgSendPid(target: c.c.id, s: c.c.SEL) c.pid_t {
    const Fn = *const fn (c.c.id, c.c.SEL) callconv(.c) c.pid_t;
    const send: Fn = @ptrCast(&objc_msgSend);
    return send(target, s);
}

/// Message send returning void, no extra args
fn msgSendVoid0(target: c.c.id, s: c.c.SEL) void {
    const Fn = *const fn (c.c.id, c.c.SEL) callconv(.c) void;
    const send: Fn = @ptrCast(&objc_msgSend);
    send(target, s);
}

/// Cast Class to id for message sending (Class and id have different alignments in cimport)
/// Takes the unwrapped (non-optional) class pointer after orelse check
fn classAsId(cls: *c.c.struct_objc_class) c.c.id {
    return @ptrCast(@alignCast(cls));
}
