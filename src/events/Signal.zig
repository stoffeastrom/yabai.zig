const std = @import("std");
const Allocator = std.mem.Allocator;

/// Signal types for yabai.zig event hooks
pub const Type = enum(u8) {
    unknown = 0,

    // Application events
    application_launched,
    application_terminated,
    application_front_switched,
    application_activated,
    application_deactivated,
    application_visible,
    application_hidden,

    // Window events
    window_created,
    window_destroyed,
    window_focused,
    window_moved,
    window_resized,
    window_minimized,
    window_deminimized,
    window_title_changed,

    // Space events
    space_created,
    space_destroyed,
    space_changed,

    // Display events
    display_added,
    display_removed,
    display_moved,
    display_resized,
    display_changed,

    // Mission Control events
    mission_control_enter,
    mission_control_exit,

    // System events
    dock_did_change_pref,
    dock_did_restart,
    menu_bar_hidden_changed,
    system_woke,

    pub fn fromString(str: []const u8) Type {
        const map = std.StaticStringMap(Type).initComptime(.{
            .{ "application_launched", .application_launched },
            .{ "application_terminated", .application_terminated },
            .{ "application_front_switched", .application_front_switched },
            .{ "application_activated", .application_activated },
            .{ "application_deactivated", .application_deactivated },
            .{ "application_visible", .application_visible },
            .{ "application_hidden", .application_hidden },
            .{ "window_created", .window_created },
            .{ "window_destroyed", .window_destroyed },
            .{ "window_focused", .window_focused },
            .{ "window_moved", .window_moved },
            .{ "window_resized", .window_resized },
            .{ "window_minimized", .window_minimized },
            .{ "window_deminimized", .window_deminimized },
            .{ "window_title_changed", .window_title_changed },
            .{ "space_created", .space_created },
            .{ "space_destroyed", .space_destroyed },
            .{ "space_changed", .space_changed },
            .{ "display_added", .display_added },
            .{ "display_removed", .display_removed },
            .{ "display_moved", .display_moved },
            .{ "display_resized", .display_resized },
            .{ "display_changed", .display_changed },
            .{ "mission_control_enter", .mission_control_enter },
            .{ "mission_control_exit", .mission_control_exit },
            .{ "dock_did_change_pref", .dock_did_change_pref },
            .{ "dock_did_restart", .dock_did_restart },
            .{ "menu_bar_hidden_changed", .menu_bar_hidden_changed },
            .{ "system_woke", .system_woke },
        });
        return map.get(str) orelse .unknown;
    }

    pub fn toString(self: Type) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .application_launched => "application_launched",
            .application_terminated => "application_terminated",
            .application_front_switched => "application_front_switched",
            .application_activated => "application_activated",
            .application_deactivated => "application_deactivated",
            .application_visible => "application_visible",
            .application_hidden => "application_hidden",
            .window_created => "window_created",
            .window_destroyed => "window_destroyed",
            .window_focused => "window_focused",
            .window_moved => "window_moved",
            .window_resized => "window_resized",
            .window_minimized => "window_minimized",
            .window_deminimized => "window_deminimized",
            .window_title_changed => "window_title_changed",
            .space_created => "space_created",
            .space_destroyed => "space_destroyed",
            .space_changed => "space_changed",
            .display_added => "display_added",
            .display_removed => "display_removed",
            .display_moved => "display_moved",
            .display_resized => "display_resized",
            .display_changed => "display_changed",
            .mission_control_enter => "mission_control_enter",
            .mission_control_exit => "mission_control_exit",
            .dock_did_change_pref => "dock_did_change_pref",
            .dock_did_restart => "dock_did_restart",
            .menu_bar_hidden_changed => "menu_bar_hidden_changed",
            .system_woke => "system_woke",
        };
    }
};

/// Active filter state
pub const ActiveFilter = enum(u8) {
    unspecified = 0,
    yes = 1,
    no = 2,
};

/// Pattern matching for signal filters
pub const Pattern = struct {
    pattern: []const u8,
    exclude: bool = false,

    pub fn matches(self: Pattern, value: []const u8) bool {
        const found = std.mem.indexOf(u8, value, self.pattern) != null;
        return if (self.exclude) !found else found;
    }
};

/// A signal subscription
pub const Signal = struct {
    signal_type: Type,
    command: []const u8,
    label: ?[]const u8 = null,
    app_pattern: ?Pattern = null,
    title_pattern: ?Pattern = null,
    active: ActiveFilter = .unspecified,

    pub fn deinit(self: *Signal, allocator: Allocator) void {
        allocator.free(self.command);
        if (self.label) |l| allocator.free(l);
        if (self.app_pattern) |p| allocator.free(p.pattern);
        if (self.title_pattern) |p| allocator.free(p.pattern);
    }

    /// Check if signal should be filtered out for given context
    pub fn shouldFilter(self: Signal, app: ?[]const u8, title: ?[]const u8, is_active: bool) bool {
        // Check app pattern
        if (self.app_pattern) |pattern| {
            const app_str = app orelse "";
            if (!pattern.matches(app_str)) return true;
        }

        // Check title pattern
        if (self.title_pattern) |pattern| {
            const title_str = title orelse "";
            if (!pattern.matches(title_str)) return true;
        }

        // Check active filter
        if (self.active != .unspecified) {
            const want_active = self.active == .yes;
            if (is_active != want_active) return true;
        }

        return false;
    }
};

/// Environment variable for signal execution
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Event context passed to signal handlers
pub const EventContext = struct {
    app: ?[]const u8 = null,
    title: ?[]const u8 = null,
    is_active: bool = false,
    env_vars: []const EnvVar = &.{},
};

/// Signal registry - stores and dispatches signals
pub const Registry = struct {
    allocator: Allocator,
    signals: std.ArrayList(Signal) = .{},

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.signals.items) |*signal| {
            signal.deinit(self.allocator);
        }
        self.signals.deinit(self.allocator);
    }

    /// Add a signal subscription
    pub fn add(self: *Registry, signal: Signal) !void {
        // Remove existing signal with same label
        if (signal.label) |label| {
            _ = self.removeByLabel(label);
        }
        try self.signals.append(self.allocator, signal);
    }

    /// Remove signal by label
    pub fn removeByLabel(self: *Registry, label: []const u8) bool {
        for (self.signals.items, 0..) |*signal, i| {
            if (signal.label) |l| {
                if (std.mem.eql(u8, l, label)) {
                    signal.deinit(self.allocator);
                    _ = self.signals.orderedRemove(i);
                    return true;
                }
            }
        }
        return false;
    }

    /// Remove signal by index
    pub fn removeByIndex(self: *Registry, index: usize) bool {
        if (index >= self.signals.items.len) return false;
        var signal = self.signals.orderedRemove(index);
        signal.deinit(self.allocator);
        return true;
    }

    /// Execute matching signals for an event (forks for each command)
    pub fn dispatch(self: *Registry, signal_type: Type, ctx: EventContext) void {
        for (self.signals.items) |signal| {
            if (signal.signal_type != signal_type) continue;
            if (signal.shouldFilter(ctx.app, ctx.title, ctx.is_active)) continue;

            // Fork and execute command
            const pid = std.c.fork();
            if (pid != 0) continue; // Parent continues

            // Child process: set env vars and exec
            for (ctx.env_vars) |env| {
                _ = std.c.setenv(env.name.ptr, env.value.ptr, 1);
            }

            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/env",
                "sh",
                "-c",
                @ptrCast(signal.command.ptr),
                null,
            };
            _ = std.c.execve("/usr/bin/env", &argv, std.c._environ);
            std.c.exit(1);
        }
    }

    pub fn len(self: *const Registry) usize {
        return self.signals.items.len;
    }
};

// Tests
test "Type.fromString" {
    try std.testing.expectEqual(Type.window_focused, Type.fromString("window_focused"));
    try std.testing.expectEqual(Type.application_launched, Type.fromString("application_launched"));
    try std.testing.expectEqual(Type.unknown, Type.fromString("invalid"));
}

test "Type.toString" {
    try std.testing.expectEqualStrings("window_focused", Type.window_focused.toString());
    try std.testing.expectEqualStrings("space_changed", Type.space_changed.toString());
}

test "Pattern.matches" {
    const include = Pattern{ .pattern = "Safari" };
    try std.testing.expect(include.matches("Safari"));
    try std.testing.expect(include.matches("Safari Browser"));
    try std.testing.expect(!include.matches("Firefox"));

    const exclude = Pattern{ .pattern = "Safari", .exclude = true };
    try std.testing.expect(!exclude.matches("Safari"));
    try std.testing.expect(exclude.matches("Firefox"));
}

test "Signal.shouldFilter" {
    const signal = Signal{
        .signal_type = .window_focused,
        .command = "echo test",
        .app_pattern = Pattern{ .pattern = "Safari" },
        .active = .yes,
    };

    // Matches: Safari app, is active
    try std.testing.expect(!signal.shouldFilter("Safari", null, true));

    // Filtered: wrong app
    try std.testing.expect(signal.shouldFilter("Firefox", null, true));

    // Filtered: not active
    try std.testing.expect(signal.shouldFilter("Safari", null, false));
}

test "Registry add and remove" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    // Add signals
    try registry.add(.{
        .signal_type = .window_focused,
        .command = try std.testing.allocator.dupe(u8, "echo focused"),
        .label = try std.testing.allocator.dupe(u8, "focus_handler"),
    });
    try std.testing.expectEqual(@as(usize, 1), registry.len());

    // Remove by label
    try std.testing.expect(registry.removeByLabel("focus_handler"));
    try std.testing.expectEqual(@as(usize, 0), registry.len());
}
