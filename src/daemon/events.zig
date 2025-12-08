//! Event handling functions for Daemon
//! AX observer callbacks and workspace event handlers.

const std = @import("std");
const c = @import("../platform/c.zig");
const ax = @import("../platform/accessibility.zig");
const Application = @import("../core/Application.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Config = @import("../config/Config.zig");
const Event = @import("../events/Event.zig").Event;

const log = std.log.scoped(.daemon);

/// Focus result for FFM operations
pub const FocusResult = struct {
    succeeded: bool = false,
};

/// Focus window without raising it (for autofocus mode)
pub fn focusWindowWithoutRaise(wid: Window.Id, pid: c.pid_t, ax_ref: ?c.AXUIElementRef) bool {
    // Use AX to make this the main window (focuses within the app)
    if (ax_ref) |ref| {
        const kAXMainAttribute = c.cfstr("AXMain");
        defer c.c.CFRelease(kAXMainAttribute);
        const result = c.c.AXUIElementSetAttributeValue(ref, kAXMainAttribute, c.c.kCFBooleanTrue);
        if (result != 0) {
            log.debug("ffm: AXMain failed for wid={d} (err={}), ax_ref may be stale", .{ wid, result });
        }
    }

    // Bring app to front without raising windows
    var psn: c.c.ProcessSerialNumber = undefined;
    if (c.c.GetProcessForPID(pid, &psn) != 0) {
        log.debug("ffm: GetProcessForPID failed for pid={d}", .{pid});
        return false;
    }

    const result = c.c.SetFrontProcessWithOptions(&psn, c.c.kSetFrontProcessFrontWindowOnly);
    if (result != 0) {
        log.debug("ffm: SetFrontProcessWithOptions failed for pid={d} (err={})", .{ pid, result });
        return false;
    }

    log.debug("ffm: autofocus wid={d}", .{wid});
    return true;
}

/// Focus window and raise it (for autoraise mode)
pub fn focusWindowWithRaise(wid: Window.Id, pid: c.pid_t, ax_ref: ?c.AXUIElementRef) bool {
    // Get AX element and raise
    if (ax_ref) |ref| {
        const kAXRaiseAction = c.cfstr("AXRaise");
        defer c.c.CFRelease(kAXRaiseAction);
        const kAXMainAttribute = c.cfstr("AXMain");
        defer c.c.CFRelease(kAXMainAttribute);

        _ = c.c.AXUIElementPerformAction(ref, kAXRaiseAction);
        _ = c.c.AXUIElementSetAttributeValue(ref, kAXMainAttribute, c.c.kCFBooleanTrue);
    }

    // Bring app to front
    var psn: c.c.ProcessSerialNumber = undefined;
    if (c.c.GetProcessForPID(pid, &psn) != 0) {
        log.debug("ffm: GetProcessForPID failed for pid={d}", .{pid});
        return false;
    }

    const result = c.c.SetFrontProcessWithOptions(&psn, c.c.kSetFrontProcessFrontWindowOnly);
    if (result != 0) {
        log.debug("ffm: SetFrontProcessWithOptions failed for pid={d} (err={})", .{ pid, result });
        return false;
    }

    log.debug("ffm: autoraise wid={d}", .{wid});
    return true;
}

/// Check if a window should be managed (tiled)
pub fn shouldManageWindow(win_ref: c.AXUIElementRef) bool {
    // Check role
    const role_ref = ax.copyAttributeValue(win_ref, ax.Attr.role) catch return false;
    defer c.c.CFRelease(role_ref);

    // Must be a window
    const role_str: c.CFStringRef = @ptrCast(role_ref);
    if (!ax.cfStringEquals(role_str, ax.Role.window)) {
        return false;
    }

    // Check subrole - only manage standard windows
    if (ax.copyAttributeValue(win_ref, ax.Attr.subrole)) |subrole_ref| {
        defer c.c.CFRelease(subrole_ref);
        const subrole_str: c.CFStringRef = @ptrCast(subrole_ref);

        // Skip dialogs, system dialogs, floating windows
        if (!ax.cfStringEquals(subrole_str, ax.Subrole.standard_window)) {
            return false;
        }
    } else |_| {}

    // Check minimized
    if (ax.copyAttributeValue(win_ref, ax.Attr.minimized)) |min_ref| {
        defer c.c.CFRelease(min_ref);
        if (ax.extractBool(min_ref)) return false;
    } else |_| {}

    return true;
}

/// Get app name from PID
pub fn getAppName(pid: c.pid_t, buf: []u8) ?[]const u8 {
    const name_len = c.c.proc_name(pid, buf.ptr, @intCast(buf.len));
    if (name_len <= 0) return null;
    return buf[0..@intCast(name_len)];
}
