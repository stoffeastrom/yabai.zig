const std = @import("std");
const c = @import("../platform/c.zig");
const geometry = @import("../core/geometry.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Display = @import("../core/Display.zig");
const Application = @import("../core/Application.zig");

const Point = geometry.Point;

/// Tagged union for all yabai.zig events
pub const Event = union(Type) {
    // Application events
    application_launched: ApplicationEvent,
    application_terminated: ApplicationEvent,
    application_front_switched: ApplicationEvent,
    application_activated: ApplicationEvent,
    application_deactivated: ApplicationEvent,
    application_visible: ApplicationEvent,
    application_hidden: ApplicationEvent,

    // Window events
    window_created: WindowEvent,
    window_destroyed: WindowEvent,
    window_focused: WindowEvent,
    window_moved: WindowEvent,
    window_resized: WindowEvent,
    window_minimized: WindowEvent,
    window_deminimized: WindowEvent,
    window_title_changed: WindowEvent,

    // SkyLight window events (low-level)
    sls_window_ordered: WindowEvent,
    sls_window_destroyed: WindowEvent,

    // Space events
    space_created: SpaceEvent,
    space_destroyed: SpaceEvent,
    space_changed: SpaceEvent,

    // Display events
    display_added: DisplayEvent,
    display_removed: DisplayEvent,
    display_moved: DisplayEvent,
    display_resized: DisplayEvent,
    display_changed: DisplayEvent,

    // Mouse events
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_dragged: MouseEvent,
    mouse_moved: MouseEvent,

    // Mission control events
    mission_control_enter: void,
    mission_control_exit: void,
    mission_control_check_for_exit: void,
    mission_control_show_all_windows: void,
    mission_control_show_front_windows: void,
    mission_control_show_desktop: void,

    // Menu events
    menu_opened: WindowEvent,
    menu_closed: WindowEvent,
    menu_bar_hidden_changed: void,

    // System events
    dock_did_restart: void,
    dock_did_change_pref: void,
    system_woke: void,

    // IPC
    daemon_message: MessageEvent,

    /// Event type enum (matches C event_type)
    pub const Type = enum(u8) {
        application_launched,
        application_terminated,
        application_front_switched,
        application_activated,
        application_deactivated,
        application_visible,
        application_hidden,

        window_created,
        window_destroyed,
        window_focused,
        window_moved,
        window_resized,
        window_minimized,
        window_deminimized,
        window_title_changed,

        sls_window_ordered,
        sls_window_destroyed,

        space_created,
        space_destroyed,
        space_changed,

        display_added,
        display_removed,
        display_moved,
        display_resized,
        display_changed,

        mouse_down,
        mouse_up,
        mouse_dragged,
        mouse_moved,

        mission_control_enter,
        mission_control_exit,
        mission_control_check_for_exit,
        mission_control_show_all_windows,
        mission_control_show_front_windows,
        mission_control_show_desktop,

        menu_opened,
        menu_closed,
        menu_bar_hidden_changed,

        dock_did_restart,
        dock_did_change_pref,
        system_woke,

        daemon_message,

        pub fn name(self: Type) []const u8 {
            return @tagName(self);
        }
    };

    /// Application event payload
    pub const ApplicationEvent = struct {
        pid: c.pid_t,
        /// Optional - may be set by handler after lookup
        connection: ?c_int = null,
    };

    /// Window event payload
    pub const WindowEvent = struct {
        window_id: Window.Id,
        /// Optional - owner PID if known
        pid: ?c.pid_t = null,
    };

    /// Space event payload
    pub const SpaceEvent = struct {
        space_id: Space.Id,
        /// Display UUID if known
        display_id: ?Display.Id = null,
    };

    /// Display event payload
    pub const DisplayEvent = struct {
        display_id: Display.Id,
        /// CGDisplayChangeSummaryFlags if applicable
        flags: u32 = 0,
    };

    /// Mouse event payload
    pub const MouseEvent = struct {
        point: Point,
        /// Window under cursor if known
        window_id: ?Window.Id = null,
        /// Button for down/up events
        button: u8 = 0,
    };

    /// IPC message event payload
    pub const MessageEvent = struct {
        /// File descriptor for response
        sockfd: std.posix.fd_t,
        /// Message content (not owned - valid only during handling)
        message: []const u8,
    };

    /// Get the type of this event
    pub fn getType(self: Event) Type {
        return std.meta.activeTag(self);
    }

    /// Get human-readable name
    pub fn name(self: Event) []const u8 {
        return self.getType().name();
    }

    /// Check if this is an application event
    pub fn isApplicationEvent(self: Event) bool {
        return switch (self) {
            .application_launched,
            .application_terminated,
            .application_front_switched,
            .application_activated,
            .application_deactivated,
            .application_visible,
            .application_hidden,
            => true,
            else => false,
        };
    }

    /// Check if this is a window event
    pub fn isWindowEvent(self: Event) bool {
        return switch (self) {
            .window_created,
            .window_destroyed,
            .window_focused,
            .window_moved,
            .window_resized,
            .window_minimized,
            .window_deminimized,
            .window_title_changed,
            .sls_window_ordered,
            .sls_window_destroyed,
            .menu_opened,
            .menu_closed,
            => true,
            else => false,
        };
    }

    /// Check if this is a space event
    pub fn isSpaceEvent(self: Event) bool {
        return switch (self) {
            .space_created, .space_destroyed, .space_changed => true,
            else => false,
        };
    }

    /// Check if this is a display event
    pub fn isDisplayEvent(self: Event) bool {
        return switch (self) {
            .display_added,
            .display_removed,
            .display_moved,
            .display_resized,
            .display_changed,
            => true,
            else => false,
        };
    }

    /// Check if this is a mouse event
    pub fn isMouseEvent(self: Event) bool {
        return switch (self) {
            .mouse_down, .mouse_up, .mouse_dragged, .mouse_moved => true,
            else => false,
        };
    }

    /// Check if this is a mission control event
    pub fn isMissionControlEvent(self: Event) bool {
        return switch (self) {
            .mission_control_enter,
            .mission_control_exit,
            .mission_control_check_for_exit,
            .mission_control_show_all_windows,
            .mission_control_show_front_windows,
            .mission_control_show_desktop,
            => true,
            else => false,
        };
    }
};

/// Signal types for external notification (shell commands)
pub const Signal = enum(u8) {
    unknown,

    application_launched,
    application_terminated,
    application_front_switched,
    application_activated,
    application_deactivated,
    application_visible,
    application_hidden,

    window_created,
    window_destroyed,
    window_focused,
    window_moved,
    window_resized,
    window_minimized,
    window_deminimized,
    window_title_changed,

    space_created,
    space_destroyed,
    space_changed,

    display_added,
    display_removed,
    display_moved,
    display_resized,
    display_changed,

    mission_control_enter,
    mission_control_exit,

    dock_did_change_pref,
    dock_did_restart,

    menu_bar_hidden_changed,
    system_woke,

    pub fn name(self: Signal) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(str: []const u8) Signal {
        inline for (std.meta.fields(Signal)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return .unknown;
    }

    /// Convert from Event.Type to Signal (not all events have signals)
    pub fn fromEventType(event_type: Event.Type) ?Signal {
        return switch (event_type) {
            .application_launched => .application_launched,
            .application_terminated => .application_terminated,
            .application_front_switched => .application_front_switched,
            .application_activated => .application_activated,
            .application_deactivated => .application_deactivated,
            .application_visible => .application_visible,
            .application_hidden => .application_hidden,
            .window_created => .window_created,
            .window_destroyed => .window_destroyed,
            .window_focused => .window_focused,
            .window_moved => .window_moved,
            .window_resized => .window_resized,
            .window_minimized => .window_minimized,
            .window_deminimized => .window_deminimized,
            .window_title_changed => .window_title_changed,
            .space_created => .space_created,
            .space_destroyed => .space_destroyed,
            .space_changed => .space_changed,
            .display_added => .display_added,
            .display_removed => .display_removed,
            .display_moved => .display_moved,
            .display_resized => .display_resized,
            .display_changed => .display_changed,
            .mission_control_enter => .mission_control_enter,
            .mission_control_exit => .mission_control_exit,
            .dock_did_restart => .dock_did_restart,
            .dock_did_change_pref => .dock_did_change_pref,
            .menu_bar_hidden_changed => .menu_bar_hidden_changed,
            .system_woke => .system_woke,
            // Events without corresponding signals
            .sls_window_ordered,
            .sls_window_destroyed,
            .mouse_down,
            .mouse_up,
            .mouse_dragged,
            .mouse_moved,
            .mission_control_check_for_exit,
            .mission_control_show_all_windows,
            .mission_control_show_front_windows,
            .mission_control_show_desktop,
            .menu_opened,
            .menu_closed,
            .daemon_message,
            => null,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Event type tagging" {
    const event = Event{ .window_created = .{ .window_id = 123 } };
    try std.testing.expectEqual(Event.Type.window_created, event.getType());
    try std.testing.expect(event.isWindowEvent());
    try std.testing.expect(!event.isApplicationEvent());
}

test "Event.Type name" {
    try std.testing.expectEqualStrings("window_created", Event.Type.window_created.name());
    try std.testing.expectEqualStrings("application_launched", Event.Type.application_launched.name());
}

test "Signal fromString" {
    try std.testing.expectEqual(Signal.window_created, Signal.fromString("window_created"));
    try std.testing.expectEqual(Signal.unknown, Signal.fromString("not_a_signal"));
}

test "Signal fromEventType" {
    try std.testing.expectEqual(Signal.window_created, Signal.fromEventType(.window_created).?);
    try std.testing.expectEqual(@as(?Signal, null), Signal.fromEventType(.daemon_message));
}

test "ApplicationEvent default values" {
    const event = Event.ApplicationEvent{ .pid = 123 };
    try std.testing.expectEqual(@as(c.pid_t, 123), event.pid);
    try std.testing.expectEqual(@as(?c_int, null), event.connection);
}

test "MouseEvent default values" {
    const event = Event.MouseEvent{ .point = .{ .x = 10, .y = 20 } };
    try std.testing.expectEqual(@as(f64, 10), event.point.x);
    try std.testing.expectEqual(@as(?Window.Id, null), event.window_id);
    try std.testing.expectEqual(@as(u8, 0), event.button);
}
