//! Observer setup functions for Daemon
//! Handles workspace, display, and mouse event tap observers.

const std = @import("std");
const c = @import("../platform/c.zig");
const WorkspaceObserver = @import("../platform/WorkspaceObserver.zig").WorkspaceObserver;

const log = std.log.scoped(.daemon);

/// Start workspace observer
pub fn startWorkspaceObserver(
    workspace_observer: *?WorkspaceObserver,
    handler: WorkspaceObserver.EventHandler,
) void {
    workspace_observer.* = WorkspaceObserver.init(handler) catch {
        log.err("failed to initialize workspace observer", .{});
        return;
    };
    log.info("workspace observer started", .{});
}

/// Start display reconfiguration observer
pub fn startDisplayObserver(callback: c.c.CGDisplayReconfigurationCallBack) void {
    const result = c.c.CGDisplayRegisterReconfigurationCallback(callback, null);
    if (result != 0) {
        log.err("failed to register display reconfiguration callback: {}", .{result});
        return;
    }
    log.info("display observer started", .{});
}

/// Stop display reconfiguration observer
pub fn stopDisplayObserver(callback: c.c.CGDisplayReconfigurationCallBack) void {
    _ = c.c.CGDisplayRemoveReconfigurationCallback(callback, null);
}

/// Mouse event tap state for focus-follows-mouse (mouse moved only)
pub const MouseEventTap = struct {
    tap: c.c.CFMachPortRef = null,
    source: c.c.CFRunLoopSourceRef = null,

    pub fn start(
        self: *MouseEventTap,
        callback: c.c.CGEventTapCallBack,
    ) bool {
        if (self.tap != null) return true; // Already started

        const event_mask: u64 = (1 << c.c.kCGEventMouseMoved);

        self.tap = c.c.CGEventTapCreate(
            c.c.kCGSessionEventTap,
            c.c.kCGHeadInsertEventTap,
            c.c.kCGEventTapOptionDefault,
            event_mask,
            callback,
            null,
        );

        if (self.tap == null) {
            log.err("failed to create mouse event tap - check accessibility permissions", .{});
            return false;
        }

        self.source = c.c.CFMachPortCreateRunLoopSource(null, self.tap, 0);
        if (self.source == null) {
            log.err("failed to create mouse event tap run loop source", .{});
            c.c.CFRelease(self.tap);
            self.tap = null;
            return false;
        }

        c.c.CFRunLoopAddSource(c.c.CFRunLoopGetMain(), self.source, c.c.kCFRunLoopDefaultMode);
        c.c.CGEventTapEnable(self.tap, true);

        log.info("mouse event tap started", .{});
        return true;
    }

    pub fn stop(self: *MouseEventTap) void {
        if (self.source) |source| {
            c.c.CFRunLoopRemoveSource(c.c.CFRunLoopGetMain(), source, c.c.kCFRunLoopDefaultMode);
            c.c.CFRelease(source);
            self.source = null;
        }
        if (self.tap) |tap| {
            c.c.CGEventTapEnable(tap, false);
            c.c.CFRelease(tap);
            self.tap = null;
        }
    }

    pub fn isEnabled(self: *const MouseEventTap) bool {
        if (self.tap) |tap| {
            return c.c.CGEventTapIsEnabled(tap);
        }
        return false;
    }

    pub fn reenable(self: *MouseEventTap) void {
        if (self.tap) |tap| {
            c.c.CGEventTapEnable(tap, true);
        }
    }
};

/// Mouse drag event tap for modifier+click window operations
/// Captures left mouse down/drag/up when modifier is held
pub const MouseDragTap = struct {
    tap: c.c.CFMachPortRef = null,
    source: c.c.CFRunLoopSourceRef = null,

    pub fn start(
        self: *MouseDragTap,
        callback: c.c.CGEventTapCallBack,
    ) bool {
        if (self.tap != null) return true; // Already started

        // Listen for left mouse down, up, and dragged events
        const event_mask: u64 = (1 << c.c.kCGEventLeftMouseDown) |
            (1 << c.c.kCGEventLeftMouseUp) |
            (1 << c.c.kCGEventLeftMouseDragged) |
            (1 << c.c.kCGEventRightMouseDown) |
            (1 << c.c.kCGEventRightMouseUp) |
            (1 << c.c.kCGEventRightMouseDragged);

        self.tap = c.c.CGEventTapCreate(
            c.c.kCGSessionEventTap,
            c.c.kCGHeadInsertEventTap,
            c.c.kCGEventTapOptionDefault,
            event_mask,
            callback,
            null,
        );

        if (self.tap == null) {
            log.err("failed to create mouse drag tap - check accessibility permissions", .{});
            return false;
        }

        self.source = c.c.CFMachPortCreateRunLoopSource(null, self.tap, 0);
        if (self.source == null) {
            log.err("failed to create mouse drag tap run loop source", .{});
            c.c.CFRelease(self.tap);
            self.tap = null;
            return false;
        }

        c.c.CFRunLoopAddSource(c.c.CFRunLoopGetMain(), self.source, c.c.kCFRunLoopDefaultMode);
        c.c.CGEventTapEnable(self.tap, true);

        log.info("mouse drag tap started", .{});
        return true;
    }

    pub fn stop(self: *MouseDragTap) void {
        if (self.source) |source| {
            c.c.CFRunLoopRemoveSource(c.c.CFRunLoopGetMain(), source, c.c.kCFRunLoopDefaultMode);
            c.c.CFRelease(source);
            self.source = null;
        }
        if (self.tap) |tap| {
            c.c.CGEventTapEnable(tap, false);
            c.c.CFRelease(tap);
            self.tap = null;
        }
    }

    pub fn isEnabled(self: *const MouseDragTap) bool {
        if (self.tap) |tap| {
            return c.c.CGEventTapIsEnabled(tap);
        }
        return false;
    }

    pub fn reenable(self: *MouseDragTap) void {
        if (self.tap) |tap| {
            c.c.CGEventTapEnable(tap, true);
        }
    }
};
