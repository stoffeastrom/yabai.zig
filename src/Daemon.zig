const std = @import("std");
const c = @import("platform/c.zig");
const skylight = @import("platform/skylight.zig");
const ax = @import("platform/accessibility.zig");
const runloop = @import("platform/runloop.zig");
const Server = @import("ipc/Server.zig");
const Response = @import("ipc/Response.zig");
const Display = @import("core/Display.zig");
const Window = @import("core/Window.zig");
const Space = @import("core/Space.zig");
const Application = @import("core/Application.zig");
const geometry = @import("core/geometry.zig");
const Displays = @import("state/Displays.zig");
const Windows = @import("state/Windows.zig");
const Spaces = @import("state/Spaces.zig");
const Apps = @import("state/Apps.zig");
const Config = @import("config/Config.zig");
const WorkspaceObserver = @import("platform/WorkspaceObserver.zig").WorkspaceObserver;
const Event = @import("events/Event.zig").Event;
const sa_extractor = @import("sa/extractor.zig");
const sa_patterns = @import("sa/patterns.zig");
const SAClient = @import("sa/client.zig").Client;

const log = std.log.scoped(.daemon);

pub const MAXLEN = 512;

/// SA (Scripting Addition) capabilities discovered at runtime
pub const SACapabilities = struct {
    /// Whether SA functions were discovered successfully
    available: bool = false,
    /// Number of functions discovered (out of 7)
    discovered_count: usize = 0,
    /// Individual function availability
    can_add_space: bool = false,
    can_remove_space: bool = false,
    can_move_space: bool = false,
    can_focus_window: bool = false,
    /// Discovered function addresses (for future use)
    discovery: ?sa_extractor.DiscoveryResult = null,
};

pub const Daemon = struct {
    allocator: std.mem.Allocator,

    // Core state
    pid: c.pid_t = 0,
    connection: c_int = 0,
    skylight: *const skylight.SkyLight,

    // Paths
    socket_path: [MAXLEN]u8 = undefined,
    sa_socket_path: [MAXLEN]u8 = undefined,
    lock_path: [MAXLEN]u8 = undefined,
    config_path: [4096]u8 = undefined,

    // Lock file handle
    lock_fd: ?std.posix.fd_t = null,

    // Window levels
    layer_normal: c_int = 0,
    layer_below: c_int = 0,
    layer_above: c_int = 0,

    // Run loop state (atomic for signal handler safety)
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // IPC server
    server: ?Server = null,

    // Workspace observer (NSWorkspace notifications)
    workspace_observer: ?WorkspaceObserver = null,

    // State
    displays: Displays,
    spaces: Spaces,
    windows: Windows,
    apps: Apps,

    // Configuration
    config: Config,

    // SA capabilities (discovered at startup)
    sa: SACapabilities = .{},

    // SA client for communicating with injected payload
    sa_client: ?SAClient = null,

    // Event tap for focus follows mouse
    mouse_event_tap: c.c.CFMachPortRef = null,
    mouse_event_source: c.c.CFRunLoopSourceRef = null,
    ffm_window_id: u32 = 0, // One-shot: window ID that FFM is currently focusing (cleared on focus confirm)
    last_ffm_time: i64 = 0, // Timestamp of last FFM focus attempt (nanoseconds)
    last_validation_time: i64 = 0, // Timestamp of last state validation

    // Global instance pointer for static callbacks
    var instance: ?*Self = null;

    const Self = @This();

    /// Signal handler for SIGINT/SIGTERM
    fn handleSignal(sig: c_int) callconv(.c) void {
        _ = sig;
        if (instance) |self| {
            self.running.store(false, .release);
        }
    }

    pub const InitError = error{
        NoUser,
        RunningAsRoot,
        NoAccessibility,
        SeparateSpacesDisabled,
        LockFileCreate,
        LockFileAcquire,
        SkylightInit,
        ServerInit,
    };

    pub const InitOptions = struct {
        skip_checks: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) InitError!Self {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: InitOptions) InitError!Self {
        var self = Self{
            .allocator = allocator,
            .skylight = undefined,
            .displays = Displays.init(allocator),
            .spaces = Spaces.init(allocator),
            .windows = Windows.init(allocator),
            .apps = Apps.init(allocator),
            .config = Config.initWithAllocator(allocator),
        };

        // Check preconditions (can be skipped for testing)
        if (!options.skip_checks) {
            try self.checkPreconditions();
        }

        // Initialize paths
        try self.initPaths();

        // Acquire lock file
        try self.acquireLock();

        // Initialize macOS subsystems
        try self.initMacOS();

        // Note: Server is started later via startServer() after the struct is at its final address

        return self;
    }

    /// Start the IPC server. Must be called after init, once the Daemon struct is at its final address.
    pub fn startServer(self: *Self) InitError!void {
        self.server = Server.init(self.allocator, handleMessage, self) catch {
            log.err("failed to initialize IPC server", .{});
            return error.ServerInit;
        };

        self.server.?.addToRunLoop() catch {
            log.err("failed to add server to run loop", .{});
            self.server.?.deinit();
            self.server = null;
            return error.ServerInit;
        };
    }

    /// Start the workspace observer. Must be called after init.
    pub fn startWorkspaceObserver(self: *Self) void {
        self.workspace_observer = WorkspaceObserver.init(handleWorkspaceEvent) catch {
            log.err("failed to initialize workspace observer", .{});
            return;
        };
        log.info("workspace observer started", .{});
    }

    /// Start mouse event tap for focus follows mouse
    pub fn startMouseEventTap(self: *Self) void {
        if (self.config.focus_follows_mouse == .disabled) return;
        if (self.mouse_event_tap != null) return;

        // Create event tap for mouse moved events
        const event_mask: u64 = (1 << c.c.kCGEventMouseMoved);

        self.mouse_event_tap = c.c.CGEventTapCreate(
            c.c.kCGSessionEventTap,
            c.c.kCGHeadInsertEventTap,
            c.c.kCGEventTapOptionDefault,
            event_mask,
            mouseEventCallback,
            null,
        );

        if (self.mouse_event_tap == null) {
            log.err("failed to create mouse event tap - check accessibility permissions", .{});
            return;
        }

        self.mouse_event_source = c.c.CFMachPortCreateRunLoopSource(null, self.mouse_event_tap, 0);
        if (self.mouse_event_source == null) {
            log.err("failed to create mouse event tap run loop source", .{});
            c.c.CFRelease(self.mouse_event_tap);
            self.mouse_event_tap = null;
            return;
        }

        c.c.CFRunLoopAddSource(c.c.CFRunLoopGetMain(), self.mouse_event_source, c.c.kCFRunLoopDefaultMode);
        c.c.CGEventTapEnable(self.mouse_event_tap, true);

        log.info("focus follows mouse enabled (mode={})", .{self.config.focus_follows_mouse});
    }

    /// Stop mouse event tap
    pub fn stopMouseEventTap(self: *Self) void {
        if (self.mouse_event_source) |source| {
            c.c.CFRunLoopRemoveSource(c.c.CFRunLoopGetMain(), source, c.c.kCFRunLoopDefaultMode);
            c.c.CFRelease(source);
            self.mouse_event_source = null;
        }
        if (self.mouse_event_tap) |tap| {
            c.c.CGEventTapEnable(tap, false);
            c.c.CFRelease(tap);
            self.mouse_event_tap = null;
        }
    }

    /// Start display reconfiguration observer
    pub fn startDisplayObserver(self: *Self) void {
        _ = self;
        const result = c.c.CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, null);
        if (result != 0) {
            log.err("failed to register display reconfiguration callback: {}", .{result});
            return;
        }
        log.info("display observer started", .{});
    }

    /// Stop display reconfiguration observer
    pub fn stopDisplayObserver(self: *Self) void {
        _ = self;
        _ = c.c.CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, null);
    }

    /// Display reconfiguration callback
    fn displayReconfigurationCallback(
        display_id: c.c.CGDirectDisplayID,
        flags: u32,
        user_info: ?*anyopaque,
    ) callconv(.c) void {
        _ = user_info;

        const self = instance orelse return;
        if (self.shutting_down.load(.acquire)) return;

        const kCGDisplayBeginConfigurationFlag: u32 = 1 << 0;
        const kCGDisplayAddFlag: u32 = 1 << 4;
        const kCGDisplayRemoveFlag: u32 = 1 << 5;

        if (flags & kCGDisplayBeginConfigurationFlag != 0) return;

        const is_add = flags & kCGDisplayAddFlag != 0;
        const is_remove = flags & kCGDisplayRemoveFlag != 0;
        const is_final = flags == 0;

        if (is_remove) {
            log.info("display removed: {}", .{display_id});
            _ = self.displays.removeLabel(display_id);
            self.syncSpaces(); // Re-assign space labels to remaining displays
            self.applyAllSpaceLayouts();
        } else if (is_add or is_final) {
            if (is_add) {
                log.info("display added: {}", .{display_id});
            }

            // Give macOS time to settle
            std.Thread.sleep(500 * std.time.ns_per_ms);

            // Re-match displays, sync spaces, and re-apply rules
            self.matchDisplays();
            self.syncSpaces();
            self.reapplyRules();
            self.applyAllSpaceLayouts();
        }
    }

    /// Re-apply rules to all tracked windows
    fn reapplyRules(self: *Self) void {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const wid = entry.key_ptr.*;
            const win = entry.value_ptr;

            var name_buf: [256]u8 = undefined;
            const name_len = c.c.proc_name(win.pid, &name_buf, 256);
            if (name_len <= 0) continue;
            const app_name = name_buf[0..@intCast(name_len)];

            const rules = self.config.findMatchingRules(app_name, null, self.allocator) catch continue;
            defer if (rules.len > 0) self.allocator.free(rules);

            for (rules) |rule| {
                if (rule.space) |space_name| {
                    if (self.resolveSpaceName(space_name)) |target_space| {
                        if (target_space != win.space_id) {
                            Space.moveWindows(&[_]u32{wid}, target_space) catch continue;
                            log.info("rule: moved {s} window {} to space {s}", .{ app_name, wid, space_name });
                            win.space_id = target_space;
                        }
                    }
                }
            }
        }
    }

    /// Mouse event callback for focus follows mouse
    fn mouseEventCallback(
        proxy: c.c.CGEventTapProxy,
        event_type: c.c.CGEventType,
        event: c.c.CGEventRef,
        user_info: ?*anyopaque,
    ) callconv(.c) c.c.CGEventRef {
        _ = proxy;
        _ = user_info;

        const self = instance orelse return event;

        // Check if shutting down
        if (self.shutting_down.load(.acquire)) return event;

        if (event_type == c.c.kCGEventTapDisabledByTimeout or
            event_type == c.c.kCGEventTapDisabledByUserInput)
        {
            // Re-enable the tap if it gets disabled
            if (self.mouse_event_tap) |tap| {
                log.warn("ffm: event tap was disabled, re-enabling", .{});
                c.c.CGEventTapEnable(tap, true);
                // Verify it's actually enabled
                if (!c.c.CGEventTapIsEnabled(tap)) {
                    log.err("ffm: failed to re-enable event tap - FFM will stop working", .{});
                }
            }
            return event;
        }

        if (event_type != c.c.kCGEventMouseMoved) return event;
        if (self.config.focus_follows_mouse == .disabled) return event;

        // Debounce: skip if last focus attempt was too recent (50ms)
        const now: i64 = @truncate(std.time.nanoTimestamp());
        const elapsed_ms = @divFloor(now - self.last_ffm_time, std.time.ns_per_ms);
        if (elapsed_ms < 50) return event;

        // Clear stale ffm_window_id after timeout (200ms) - focus confirmation may not arrive
        if (self.ffm_window_id != 0 and elapsed_ms > 200) {
            log.debug("ffm: clearing stale ffm_window_id={d} (timeout)", .{self.ffm_window_id});
            self.ffm_window_id = 0;
        }

        // Periodically validate focused_window_id still exists (every 500ms)
        if (elapsed_ms > 500) {
            if (self.windows.getFocusedId()) |focused_wid| {
                if (Window.getSpace(focused_wid) == 0) {
                    log.debug("ffm: focused_window_id={d} no longer exists, clearing", .{focused_wid});
                    self.windows.setFocused(null);
                }
            }
        }

        // Get cursor position
        var point = c.c.CGEventGetLocation(event);

        // Use SkyLight to find window under cursor (respects z-order)
        var window_point: c.CGPoint = undefined;
        var window_id: u32 = 0;
        var window_cid: c_int = 0;

        _ = self.skylight.SLSFindWindowAndOwner(
            self.connection,
            0,
            1,
            0,
            &point,
            &window_point,
            &window_id,
            &window_cid,
        );

        // Skip our own windows
        if (window_cid == self.connection) {
            _ = self.skylight.SLSFindWindowAndOwner(
                self.connection,
                @intCast(window_id),
                -1,
                0,
                &point,
                &window_point,
                &window_id,
                &window_cid,
            );
        }

        if (window_id == 0) return event;

        // Skip if already focused
        if (self.windows.getFocusedId() == window_id) return event;

        // Check if window is tracked/managed
        const win_info = self.windows.getWindow(window_id) orelse return event;

        // Validate the window still exists (guards against stale tracking)
        const actual_space = Window.getSpace(window_id);
        if (actual_space == 0) {
            // Window no longer exists - clean up stale tracking
            log.debug("ffm: wid={d} no longer exists, cleaning up", .{window_id});
            _ = self.windows.removeWindow(window_id);
            if (self.windows.getFocusedId() == window_id) {
                self.windows.setFocused(null);
            }
            return event;
        }

        log.debug("ffm: mouse over wid={d} (focused={?})", .{ window_id, self.windows.getFocusedId() });

        // Set one-shot flag BEFORE focusing (prevents re-entry and signals pending focus)
        self.ffm_window_id = window_id;
        self.last_ffm_time = now;

        // Focus the window
        var focus_succeeded = false;
        if (self.config.focus_follows_mouse == .autofocus) {
            focus_succeeded = self.focusWindowWithoutRaise(window_id, win_info.pid, win_info.ax_ref);
        } else if (self.config.focus_follows_mouse == .autoraise) {
            focus_succeeded = self.focusWindowWithRaise(window_id, win_info.pid);
        }

        if (focus_succeeded) {
            // Update our tracking immediately (don't wait for notification)
            self.windows.setFocused(window_id);
        } else {
            // Focus failed - clear the flag so we can retry
            self.ffm_window_id = 0;
        }

        return event;
    }

    /// Focus window without raising it (for autofocus mode)
    /// Returns true if focus succeeded
    fn focusWindowWithoutRaise(_: *Self, wid: Window.Id, pid: c.pid_t, ax_ref: ?c.AXUIElementRef) bool {
        // Use AX to make this the main window (focuses within the app)
        if (ax_ref) |ref| {
            const kAXMainAttribute = c.cfstr("AXMain");
            defer c.c.CFRelease(kAXMainAttribute);
            const result = c.c.AXUIElementSetAttributeValue(ref, kAXMainAttribute, c.c.kCFBooleanTrue);
            if (result != 0) {
                // AX error - element may be stale
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
    /// Returns true if focus succeeded
    fn focusWindowWithRaise(self: *Self, wid: Window.Id, pid: c.pid_t) bool {
        var ax_success = false;

        // Get AX element and raise
        if (self.windows.getWindow(wid)) |win_info| {
            if (win_info.ax_ref) |ax_ref| {
                const kAXRaiseAction = c.cfstr("AXRaise");
                defer c.c.CFRelease(kAXRaiseAction);
                const kAXMainAttribute = c.cfstr("AXMain");
                defer c.c.CFRelease(kAXMainAttribute);

                const raise_result = c.c.AXUIElementPerformAction(ax_ref, kAXRaiseAction);
                const main_result = c.c.AXUIElementSetAttributeValue(ax_ref, kAXMainAttribute, c.c.kCFBooleanTrue);

                ax_success = (raise_result == 0 and main_result == 0);
                if (!ax_success) {
                    log.debug("ffm: AX raise/main failed for wid={d} (raise={}, main={})", .{ wid, raise_result, main_result });
                }
            }
        }

        // Also bring app to front
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

    /// Handle workspace events from NSWorkspace notifications
    fn handleWorkspaceEvent(event: Event) void {
        const self = instance orelse return;

        // Check if shutting down
        if (self.shutting_down.load(.acquire)) return;

        switch (event) {
            .application_launched => |e| {
                if (e.pid > 0 and e.pid != self.pid) {
                    self.handleApplicationLaunched(e.pid);
                }
            },
            .application_terminated => |e| {
                if (e.pid > 0) {
                    self.handleApplicationTerminated(e.pid);
                }
            },
            .application_front_switched => |e| {
                log.debug("app activated: pid={d}", .{e.pid});
                self.handleApplicationFrontSwitched(e.pid);
            },
            .application_hidden => |e| {
                log.debug("app hidden: pid={d}", .{e.pid});
                self.handleApplicationHidden(e.pid);
            },
            .application_visible => |e| {
                log.debug("app visible: pid={d}", .{e.pid});
                self.handleApplicationVisible(e.pid);
            },
            .space_changed => |_| {
                log.debug("space changed", .{});
                self.handleSpaceChanged();
            },
            .display_changed => |_| {
                log.debug("display changed", .{});
                self.handleDisplayChanged();
            },
            .system_woke => {
                log.info("system woke - rebuilding layouts", .{});
                self.handleSystemWoke();
            },
            .menu_bar_hidden_changed => {
                log.debug("menu bar visibility changed", .{});
            },
            .dock_did_restart => {
                log.info("dock restarted", .{});
            },
            .dock_did_change_pref => {
                log.debug("dock preferences changed", .{});
            },
            else => {},
        }
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown to all callbacks - they should check this and exit early
        self.shutting_down.store(true, .release);

        // Clear instance pointer - callbacks will get null and return early
        instance = null;

        // Small delay to let in-flight callbacks complete
        std.Thread.sleep(50 * std.time.ns_per_ms);

        self.stopMouseEventTap();
        self.stopDisplayObserver();
        if (self.workspace_observer) |*obs| {
            obs.deinit();
        }
        if (self.server) |*srv| {
            srv.deinit();
        }
        self.config.deinit();
        self.apps.deinit();
        self.windows.deinit();
        self.spaces.deinit();
        self.displays.deinit();
        if (self.lock_fd) |fd| {
            std.posix.close(fd);
            std.posix.unlink(std.mem.sliceTo(&self.lock_path, 0)) catch {};
        }
    }

    fn checkPreconditions(self: *Self) InitError!void {
        _ = self;

        // Check not running as root
        if (c.c.getuid() == 0) {
            log.err("running as root is not allowed", .{});
            return error.RunningAsRoot;
        }

        // Check accessibility permissions
        if (!ax.isProcessTrustedWithOptions(true)) {
            log.err("could not access accessibility features", .{});
            return error.NoAccessibility;
        }
    }

    fn initPaths(self: *Self) InitError!void {
        const user = std.posix.getenv("USER") orelse {
            log.err("'env USER' not set", .{});
            return error.NoUser;
        };

        // Format socket paths
        _ = std.fmt.bufPrint(&self.socket_path, "/tmp/yabai.zig_{s}.socket", .{user}) catch unreachable;
        _ = std.fmt.bufPrint(&self.sa_socket_path, "/tmp/yabai-sa_{s}.socket", .{user}) catch unreachable;
        _ = std.fmt.bufPrint(&self.lock_path, "/tmp/yabai.zig_{s}.lock", .{user}) catch unreachable;

        // Null terminate for C interop
        self.socket_path[std.mem.indexOf(u8, &self.socket_path, &[_]u8{0}) orelse MAXLEN - 1] = 0;
        self.sa_socket_path[std.mem.indexOf(u8, &self.sa_socket_path, &[_]u8{0}) orelse MAXLEN - 1] = 0;
        self.lock_path[std.mem.indexOf(u8, &self.lock_path, &[_]u8{0}) orelse MAXLEN - 1] = 0;

        // Initialize SA client with socket path
        self.sa_client = SAClient.init(std.mem.sliceTo(&self.sa_socket_path, 0));
    }

    fn acquireLock(self: *Self) InitError!void {
        const path = std.mem.sliceTo(&self.lock_path, 0);

        const fd = std.posix.open(path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
        }, 0o600) catch {
            log.err("could not create lock file: {s}", .{path});
            return error.LockFileCreate;
        };

        // Try to acquire exclusive lock (non-blocking)
        std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch {
            std.posix.close(fd);
            log.err("could not acquire lock - another instance running?", .{});
            return error.LockFileAcquire;
        };

        self.lock_fd = fd;
    }

    fn initMacOS(self: *Self) InitError!void {
        // Load NSApplication (required for event loop)
        _ = c.NSApplicationLoad();

        // Get our PID
        self.pid = c.getpid();

        // Initialize SkyLight
        self.skylight = skylight.get() catch {
            log.err("failed to load SkyLight framework", .{});
            return error.SkylightInit;
        };

        // Get main connection ID
        self.connection = self.skylight.SLSMainConnectionID();

        // Check "displays have separate spaces" is enabled
        if (self.skylight.SLSGetSpaceManagementMode(self.connection) != 1) {
            log.err("'display has separate spaces' is disabled", .{});
            return error.SeparateSpacesDisabled;
        }

        // Get window level constants
        self.layer_normal = c.c.CGWindowLevelForKey(c.c.kCGNormalWindowLevelKey);
        self.layer_below = c.c.CGWindowLevelForKey(c.c.kCGDesktopIconWindowLevelKey);
        self.layer_above = c.c.CGWindowLevelForKey(c.c.kCGFloatingWindowLevelKey);

        // Ignore SIGCHLD and SIGPIPE
        var sig_action: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.CHLD, &sig_action, null);
        std.posix.sigaction(std.posix.SIG.PIPE, &sig_action, null);

        // Handle SIGINT/SIGTERM for clean shutdown
        const stop_action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &stop_action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &stop_action, null);

        log.info("yabai.zig started (pid={d}, connection={d})", .{ self.pid, self.connection });
    }

    /// Discover SA (Scripting Addition) capabilities by analyzing Dock.app
    pub fn discoverSACapabilities(self: *Self) void {
        const dock_path = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";

        // Read Dock binary
        const dock_data = std.fs.cwd().readFileAlloc(self.allocator, dock_path, 32 * 1024 * 1024) catch |err| {
            log.warn("SA: cannot read Dock binary: {}", .{err});
            return;
        };
        defer self.allocator.free(dock_data);

        // Extract arm64 slice
        const binary_data = sa_extractor.extractArm64Slice(dock_data) orelse {
            log.warn("SA: no arm64 slice in Dock binary", .{});
            return;
        };

        // Discover functions
        const discovery = sa_extractor.discoverFunctions(self.allocator, binary_data) catch |err| {
            log.warn("SA: function discovery failed: {}", .{err});
            return;
        };

        // Store results
        self.sa.discovery = discovery;
        self.sa.discovered_count = discovery.foundCount();

        // Check individual capabilities
        const funcs = discovery.functions;
        self.sa.can_add_space = funcs[@intFromEnum(sa_patterns.FunctionType.add_space)].found;
        self.sa.can_remove_space = funcs[@intFromEnum(sa_patterns.FunctionType.remove_space)].found;
        self.sa.can_move_space = funcs[@intFromEnum(sa_patterns.FunctionType.move_space)].found;
        self.sa.can_focus_window = funcs[@intFromEnum(sa_patterns.FunctionType.set_front_window)].found;

        self.sa.available = self.sa.discovered_count > 0;

        // Log results
        if (self.sa.available) {
            log.info("SA: discovered {d}/7 functions", .{self.sa.discovered_count});
            if (self.sa.can_add_space and self.sa.can_remove_space and self.sa.can_move_space) {
                log.info("SA: space management available", .{});
            }
            if (self.sa.can_focus_window) {
                log.info("SA: window focus available", .{});
            }
        } else {
            log.info("SA: no functions discovered - advanced features unavailable", .{});
        }
    }

    fn initServer(self: *Self) InitError!void {
        self.server = Server.init(self.allocator, handleMessage, self) catch {
            log.err("failed to initialize IPC server", .{});
            return error.ServerInit;
        };

        self.server.?.addToRunLoop() catch {
            log.err("failed to add server to run loop", .{});
            self.server.?.deinit();
            self.server = null;
            return error.ServerInit;
        };
    }

    /// Handle incoming IPC message using typed command parsing
    fn handleMessage(client_fd: std.posix.socket_t, message: []const u8, context: ?*anyopaque) void {
        const context_ptr = context orelse {
            log.err("handleMessage: null context", .{});
            Server.sendErr(client_fd, Response.err(.unknown_domain));
            return;
        };
        const self: *Self = @ptrCast(@alignCast(context_ptr));

        // Check if shutting down
        if (self.shutting_down.load(.acquire)) {
            Server.sendErr(client_fd, Response.err(.unknown_domain));
            return;
        }

        // Parse message: skip 4-byte length prefix, then null-terminated args
        if (message.len < 5) {
            Server.sendErr(client_fd, Response.err(.empty_command));
            return;
        }

        // Skip length prefix
        const args_data = message[4..];

        // Special case: query commands use QueryHandler for JSON generation
        const domain = std.mem.sliceTo(args_data, 0);
        if (std.mem.eql(u8, domain, "query")) {
            self.handleQuery(client_fd, args_data[domain.len + 1 ..]);
            return;
        }

        // Special case: config --reload needs daemon-level access
        if (std.mem.eql(u8, domain, "config")) {
            const rest = args_data[domain.len + 1 ..];
            const key = std.mem.sliceTo(rest, 0);
            if (std.mem.eql(u8, key, "--reload")) {
                self.reloadConfig();
                Server.sendResponse(client_fd, "");
                return;
            }
        }

        // Special case: space --rebuild needs daemon-level access
        if (std.mem.eql(u8, domain, "space")) {
            const rest = args_data[domain.len + 1 ..];
            const cmd = std.mem.sliceTo(rest, 0);
            if (std.mem.eql(u8, cmd, "--rebuild")) {
                self.rebuildCurrentLayout();
                Server.sendResponse(client_fd, "");
                return;
            }
        }

        // Parse using typed Message system
        const Message = @import("ipc/Message.zig");
        const CommandHandler = @import("ipc/CommandHandler.zig");

        const cmd = Message.parseNullSeparated(args_data) catch |err| {
            const code: Response.ErrorCode = switch (err) {
                error.EmptyCommand => .empty_command,
                error.UnknownDomain => .unknown_domain,
                error.UnknownCommand => .unknown_command,
                error.MissingArgument => .missing_argument,
                error.InvalidArgument => .invalid_argument,
                error.InvalidSelector => .invalid_selector,
            };
            Server.sendErr(client_fd, Response.err(code));
            return;
        };

        // Build execution context
        var ctx = CommandHandler.Context{
            .allocator = self.allocator,
            .skylight = self.skylight,
            .connection = self.connection,
            .windows = &self.windows,
            .spaces = &self.spaces,
            .displays = &self.displays,
            .config = &self.config,
            .applyLayout = applyLayoutCallback,
            .getBoundsForSpace = getBoundsCallback,
        };

        // Execute the command
        const result = CommandHandler.execute(&ctx, cmd);

        switch (result) {
            .ok => |response| Server.sendResponse(client_fd, response),
            .err => |err| Server.sendErr(client_fd, err),
        }
    }

    /// Callback for CommandHandler to apply layout
    fn applyLayoutCallback(ctx: *@import("ipc/CommandHandler.zig").Context, space_id: u64) void {
        _ = ctx;
        const self = instance orelse return;
        self.applyLayoutToSpace(space_id);
    }

    /// Callback for CommandHandler to get bounds for a space
    fn getBoundsCallback(ctx: *@import("ipc/CommandHandler.zig").Context, space_id: u64) ?geometry.Rect {
        _ = ctx;
        const self = instance orelse return null;
        return self.getBoundsForSpace(space_id);
    }

    fn handleQuery(self: *Self, client_fd: std.posix.socket_t, args: []const u8) void {
        const QueryHandler = @import("ipc/QueryHandler.zig");
        QueryHandler.handleQuery(.{
            .allocator = self.allocator,
            .skylight = self.skylight,
            .connection = self.connection,
            .displays = &self.displays,
        }, client_fd, args);
    }

    // ============================================================================
    // Window/Space helper types and functions
    // ============================================================================

    const WindowInfo = struct {
        id: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    };

    fn getVisibleWindows(self: *Self) ?[]WindowInfo {
        const sl = self.skylight;
        const cid = self.connection;

        // Get current space
        const current_space = self.getCurrentSpaceId() orelse return null;

        // Create CFArray with space ID
        var space_id = current_space;
        const space_num = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &space_id);
        if (space_num == null) return null;
        defer c.c.CFRelease(space_num);

        const space_array = c.c.CFArrayCreate(null, @ptrCast(@constCast(&space_num)), 1, &c.c.kCFTypeArrayCallBacks);
        if (space_array == null) return null;
        defer c.c.CFRelease(space_array);

        // Get windows
        var set_tags: u64 = 0;
        var clear_tags: u64 = 0;
        const window_list = sl.SLSCopyWindowsWithOptionsAndTags(cid, 0, space_array, 0x2, &set_tags, &clear_tags);
        if (window_list == null) return null;
        defer c.c.CFRelease(window_list);

        const count: usize = @intCast(c.c.CFArrayGetCount(window_list));
        if (count == 0) return null;

        var windows = self.allocator.alloc(WindowInfo, count) catch return null;
        var valid_count: usize = 0;

        for (0..count) |i| {
            const val = c.c.CFArrayGetValueAtIndex(window_list, @intCast(i));
            const num: c.c.CFNumberRef = @ptrCast(@constCast(val));
            var wid: u32 = 0;
            if (c.c.CFNumberGetValue(num, c.c.kCFNumberSInt32Type, &wid) == 0) continue;
            if (wid == 0) continue;

            // Filter: only normal windows (level 0)
            var level: c_int = 0;
            if (sl.SLSGetWindowLevel(cid, wid, &level) != 0) continue;
            if (level != 0) continue;

            var bounds: c.CGRect = undefined;
            if (sl.SLSGetWindowBounds(cid, wid, &bounds) != 0) continue;

            windows[valid_count] = .{
                .id = wid,
                .x = bounds.origin.x,
                .y = bounds.origin.y,
                .w = bounds.size.width,
                .h = bounds.size.height,
            };
            valid_count += 1;
        }

        if (valid_count == 0) {
            self.allocator.free(windows);
            return null;
        }

        return self.allocator.realloc(windows, valid_count) catch windows[0..valid_count];
    }

    fn spaceIdFromIndex(self: *Self, index: u64) ?u64 {
        if (index == 0) return null;
        const spaces = self.getAllSpaceIds() orelse return null;
        defer self.allocator.free(spaces);
        if (index > spaces.len) return null;
        return spaces[index - 1];
    }

    fn getCurrentSpaceId(self: *Self) ?u64 {
        _ = self;
        const main_display = Displays.getMainDisplayId();
        return Display.getCurrentSpace(main_display);
    }

    fn getAllSpaceIds(self: *Self) ?[]u64 {
        const displays = Displays.getActiveDisplayList(self.allocator) catch return null;
        defer self.allocator.free(displays);

        var all_spaces: std.ArrayList(u64) = .empty;
        for (displays) |did| {
            const spaces = Display.getSpaceList(self.allocator, did) catch continue;
            defer self.allocator.free(spaces);
            for (spaces) |sid| {
                all_spaces.append(self.allocator, sid) catch continue;
            }
        }

        if (all_spaces.items.len == 0) {
            all_spaces.deinit(self.allocator);
            return null;
        }
        return all_spaces.toOwnedSlice(self.allocator) catch null;
    }

    /// Reload config: re-apply spaces, profiles, and rules to current state
    fn reloadConfig(self: *Self) void {
        log.info("reloading config", .{});

        // Re-sync spaces (labels)
        self.syncSpaces();

        // Re-apply rules to all tracked windows
        var win_it = self.windows.iterator();
        while (win_it.next()) |entry| {
            const wid = entry.key_ptr.*;
            const win = entry.value_ptr.*;

            // Get app name
            var name_buf: [256]u8 = undefined;
            const name_len = c.c.proc_name(win.pid, &name_buf, 256);
            if (name_len <= 0) continue;
            const app_name = name_buf[0..@intCast(name_len)];

            // Find matching rules
            const rules = self.config.findMatchingRules(app_name, null, self.allocator) catch continue;
            defer if (rules.len > 0) self.allocator.free(rules);

            for (rules) |rule| {
                if (rule.space) |space_name| {
                    if (self.resolveSpaceName(space_name)) |target_space| {
                        if (target_space != win.space_id) {
                            if (self.moveWindowToSpace(wid, win.space_id, target_space)) {
                                log.info("reload: moved window {} to space {s}", .{ wid, space_name });
                            }
                        }
                    }
                }
            }
        }

        // Re-tile all spaces
        self.applyAllSpaceLayouts();
        log.info("reload complete", .{});
    }

    // ============================================================================
    // Window/Space synchronization helpers
    // ============================================================================

    /// Move a window to a different space (internal - doesn't update WindowTable).
    /// Used during initial scan before window is tracked.
    fn moveWindowToSpaceInternal(self: *Self, wid: Window.Id, to_space: u64) bool {
        // Try SA client first (more reliable)
        if (self.sa_client) |sa| {
            if (sa.moveWindowToSpace(to_space, wid)) {
                return true;
            }
        }

        // Fall back to SkyLight
        Space.moveWindows(&[_]u32{wid}, to_space) catch {
            return false;
        };

        return true;
    }

    /// Move a window to a different space.
    /// Updates WindowTable (single source of truth) and performs macOS move.
    fn moveWindowToSpace(self: *Self, wid: Window.Id, from_space: u64, to_space: u64) bool {
        if (from_space == to_space) return true;

        if (!self.moveWindowToSpaceInternal(wid, to_space)) {
            log.warn("moveWindowToSpace: failed to move wid={d}", .{wid});
            return false;
        }

        // Update WindowTable (single source of truth)
        self.windows.setWindowSpace(wid, to_space);

        return true;
    }

    // ============================================================================
    // Layout application
    // ============================================================================

    /// Apply layout to current space - tiles all windows
    fn applyCurrentLayout(self: *Self) void {
        const space_id = self.getCurrentSpaceId() orelse return;
        self.applyLayoutToSpace(space_id);
    }

    /// Apply layout to a specific space
    fn applyLayoutToSpace(self: *Self, space_id: u64) void {
        if (self.getBoundsForSpace(space_id)) |bounds| {
            self.spaces.applyLayout(space_id, bounds, &self.windows) catch |err| {
                log.err("failed to apply layout to space {d}: {}", .{ space_id, err });
            };
        }
    }

    /// Warp mouse cursor to center of window (if not already inside)
    fn warpMouseToWindow(self: *Self, wid: Window.Id) void {
        const frame = Window.getFrame(wid) catch {
            log.debug("mouse warp: failed to get frame for wid={d}", .{wid});
            return;
        };

        // Check if cursor is already inside window
        var cursor: c.CGPoint = undefined;
        if (self.skylight.SLSGetCurrentCursorLocation(self.connection, &cursor) == 0) {
            if (cursor.x >= frame.x and cursor.x <= frame.x + frame.width and
                cursor.y >= frame.y and cursor.y <= frame.y + frame.height)
            {
                log.debug("mouse warp: cursor already inside wid={d}", .{wid});
                return;
            }
        }

        // Warp to center
        const center = c.CGPoint{
            .x = frame.x + frame.width / 2,
            .y = frame.y + frame.height / 2,
        };

        _ = c.c.CGAssociateMouseAndMouseCursorPosition(0);
        _ = c.c.CGWarpMouseCursorPosition(center);
        _ = c.c.CGAssociateMouseAndMouseCursorPosition(1);
        log.debug("mouse warp: wid={d} to ({d:.0},{d:.0})", .{ wid, center.x, center.y });
    }

    /// Get bounds for a space (display bounds minus padding and external bar)
    fn getBoundsForSpace(self: *Self, space_id: u64) ?geometry.Rect {
        const display_id = self.getDisplayForSpace(space_id) orelse return null;
        var bounds = Display.getBounds(display_id);

        // Apply external bar (e.g., SketchyBar)
        const bar = self.config.external_bar;
        const apply_bar = switch (bar.position) {
            .off => false,
            .main => display_id == Displays.getMainDisplayId(),
            .all => true,
        };
        if (apply_bar) {
            bounds.y += @floatFromInt(bar.top_padding);
            bounds.height -= @floatFromInt(bar.top_padding + bar.bottom_padding);
        }

        // Note: View.setArea() applies its own padding from Spaces config
        // So we don't apply config padding here - just external_bar offset

        return bounds;
    }

    /// Flush all dirty views - applies layout to current space
    fn flushDirtyViews(self: *Self) void {
        self.applyCurrentLayout();
    }

    /// Build the BSP tree for current space from existing windows
    pub fn rebuildCurrentLayout(self: *Self) void {
        const space_id = self.getCurrentSpaceId() orelse return;
        log.debug("rebuildCurrentLayout: rebuilding space {}", .{space_id});

        // Clear existing view for THIS space only
        self.spaces.removeView(space_id);

        // Apply layout (will query WindowTable for windows)
        self.applyCurrentLayout();
    }

    fn getDisplayForSpace(self: *Self, space_id: u64) ?u32 {
        const sl = self.skylight;
        const cid = self.connection;

        const space_uuid = sl.SLSCopyManagedDisplayForSpace(cid, space_id);
        if (space_uuid == null) return null;
        defer c.c.CFRelease(space_uuid);

        // Convert CFString UUID to display ID
        const display_id = Display.getId(space_uuid);
        return if (display_id != 0) display_id else null;
    }

    /// Run the main event loop. Blocks until stop() is called.
    pub fn run(self: *Self) void {
        self.running.store(true, .release);
        log.info("entering run loop", .{});

        // Run the CFRunLoop - this is where all macOS events are delivered
        while (self.running.load(.acquire)) {
            // Process one event or timeout after 1 second
            const result = runloop.runOnce(1.0);
            switch (result) {
                .finished => {
                    // No more sources, we're done
                    log.info("run loop finished (no sources)", .{});
                    break;
                },
                .stopped => {
                    log.info("run loop stopped", .{});
                    break;
                },
                .timed_out, .handled_source => {
                    // Periodic state validation (every ~5 seconds on timeout)
                    if (result == .timed_out) {
                        self.periodicStateValidation();
                    }
                },
            }
        }

        log.info("exiting run loop", .{});
    }

    /// Stop the run loop
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        runloop.stop(runloop.getMain());
    }

    /// Periodic state validation - cleans up stale state and checks health
    fn periodicStateValidation(self: *Self) void {
        const now: i64 = @truncate(std.time.nanoTimestamp());
        const elapsed_ms = @divFloor(now - self.last_validation_time, std.time.ns_per_ms);

        // Run validation every 5 seconds
        if (elapsed_ms < 5000) return;
        self.last_validation_time = now;

        var cleaned_windows: u32 = 0;

        // Validate all tracked windows still exist (use fixed buffer, run multiple passes if needed)
        var windows_to_remove: [64]Window.Id = undefined;
        var remove_count: usize = 0;

        var win_it = self.windows.iterator();
        while (win_it.next()) |entry| {
            const wid = entry.key_ptr.*;
            const space = Window.getSpace(wid);
            if (space == 0) {
                // Window no longer exists
                if (remove_count < windows_to_remove.len) {
                    windows_to_remove[remove_count] = wid;
                    remove_count += 1;
                }
            }
        }

        // Remove stale windows
        for (windows_to_remove[0..remove_count]) |wid| {
            _ = self.windows.removeWindow(wid);
            cleaned_windows += 1;
        }

        // Clear stale focused_window_id
        if (self.windows.getFocusedId()) |focused_wid| {
            if (Window.getSpace(focused_wid) == 0) {
                self.windows.setFocused(null);
                log.debug("validation: cleared stale focused_window_id={d}", .{focused_wid});
            }
        }

        // Re-enable event tap if it got disabled
        if (self.config.focus_follows_mouse != .disabled) {
            if (self.mouse_event_tap) |tap| {
                if (!c.c.CGEventTapIsEnabled(tap)) {
                    log.warn("validation: re-enabling disabled event tap", .{});
                    c.c.CGEventTapEnable(tap, true);
                }
            } else {
                // Event tap is null but FFM is enabled - try to recreate
                log.warn("validation: event tap is null, attempting to recreate", .{});
                self.startMouseEventTap();
            }
        }

        if (cleaned_windows > 0) {
            log.info("validation: cleaned {d} stale windows", .{cleaned_windows});
        }

        // Debug memory stats
        log.debug("state: apps={d}/{d} wins={d}/{d} views={d}/{d} labels={d}/{d}", .{
            self.apps.count(),
            self.apps.capacity(),
            self.windows.count(),
            self.windows.capacity(),
            self.spaces.count(),
            self.spaces.capacity(),
            self.displays.labelCount(),
            self.displays.labelCapacity(),
        });
    }

    /// Get path to socket file as a slice
    pub fn getSocketPath(self: *const Self) []const u8 {
        return std.mem.sliceTo(&self.socket_path, 0);
    }

    /// Get path to config file as a slice
    pub fn getConfigPath(self: *const Self) []const u8 {
        const len = std.mem.indexOf(u8, &self.config_path, &[_]u8{0}) orelse 0;
        if (len == 0) return "";
        return self.config_path[0..len];
    }

    /// Set config file path
    pub fn setConfigPath(self: *Self, path: []const u8) void {
        const copy_len = @min(path.len, self.config_path.len - 1);
        @memcpy(self.config_path[0..copy_len], path[0..copy_len]);
        self.config_path[copy_len] = 0;
    }

    /// Sync config values to state (call after loading config file)
    pub fn syncConfigToState(self: *Self) void {
        self.spaces.window_gap = @intCast(self.config.window_gap);
        self.spaces.padding = .{
            .top = @intCast(self.config.top_padding),
            .bottom = @intCast(self.config.bottom_padding),
            .left = @intCast(self.config.left_padding),
            .right = @intCast(self.config.right_padding),
        };
        self.spaces.split_ratio = self.config.split_ratio;
        self.spaces.auto_balance = self.config.auto_balance;
        self.spaces.layout = switch (self.config.layout) {
            .bsp => .bsp,
            .stack => .stack,
            .float => .float,
        };

        // Update focus follows mouse event tap
        if (self.config.focus_follows_mouse != .disabled) {
            self.startMouseEventTap();
        } else {
            self.stopMouseEventTap();
        }
    }

    // ============================================================================
    // Application tracking and auto-tiling
    // ============================================================================

    /// Initialize application tracking - call after daemon is running
    pub fn startApplicationTracking(self: *Self) void {
        instance = self;

        // Match physical displays to config labels
        self.matchDisplays();

        // Sync spaces to match config (create/remove as needed)
        self.syncSpaces();

        // Now scan and track running applications
        self.scanRunningApplications();
    }

    /// Match physical displays to config labels (builtin/external)
    fn matchDisplays(self: *Self) void {
        const display_configs = self.config.displays.items;
        if (display_configs.len == 0) return;

        const displays = Displays.getActiveDisplayList(self.allocator) catch return;
        defer self.allocator.free(displays);

        for (display_configs) |cfg| {
            const matched_id: ?Display.Id = switch (cfg.match) {
                .builtin => blk: {
                    for (displays) |did| {
                        if (c.c.CGDisplayIsBuiltin(did) != 0) break :blk did;
                    }
                    break :blk null;
                },
                .external => blk: {
                    for (displays) |did| {
                        if (c.c.CGDisplayIsBuiltin(did) == 0) break :blk did;
                    }
                    break :blk null;
                },
            };

            if (matched_id) |did| {
                self.displays.setLabel(did, cfg.label) catch {};
                log.info("display: {s} -> {} ({s})", .{
                    cfg.label,
                    did,
                    if (c.c.CGDisplayIsBuiltin(did) != 0) "builtin" else "external",
                });
            }
        }
    }

    /// Sync macOS spaces to match config - create/destroy spaces as needed
    fn syncSpaces(self: *Self) void {
        const wanted = self.config.spaces.items.len;
        if (wanted == 0) return;

        const sa = self.sa_client orelse {
            log.warn("space sync: SA client not available", .{});
            return;
        };

        // Check if SA is responding
        if (!sa.isAvailable()) {
            log.warn("space sync: SA not responding (not loaded?)", .{});
            self.syncSpacesLabelsOnly();
            return;
        }

        const spaces = self.getAllSpaceIds() orelse return;
        defer self.allocator.free(spaces);

        // Filter to user spaces only (skip fullscreen/system spaces)
        var user_spaces: [64]u64 = undefined;
        var user_count: usize = 0;
        for (spaces) |sid| {
            if (Space.isUser(sid) and user_count < 64) {
                user_spaces[user_count] = sid;
                user_count += 1;
            }
        }

        log.info("space sync: have {d} user spaces, want {d}", .{ user_count, wanted });

        // Create missing spaces
        if (user_count < wanted and user_count > 0) {
            const to_create = wanted - user_count;
            const last_space = user_spaces[user_count - 1];
            for (0..to_create) |_| {
                if (sa.createSpace(last_space)) {
                    user_count += 1;
                    // Small delay to let macOS process the space creation
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                } else {
                    log.warn("space sync: failed to create space", .{});
                    break;
                }
            }
        }

        // Destroy extra empty spaces (from the end)
        if (user_count > wanted) {
            // Re-fetch spaces after potential creation
            const updated_spaces = self.getAllSpaceIds() orelse return;
            defer self.allocator.free(updated_spaces);

            var updated_user_spaces: [64]u64 = undefined;
            var updated_count: usize = 0;
            for (updated_spaces) |sid| {
                if (Space.isUser(sid) and updated_count < 64) {
                    updated_user_spaces[updated_count] = sid;
                    updated_count += 1;
                }
            }

            const to_remove = updated_count - wanted;
            var removed: usize = 0;
            var idx = updated_count;
            while (removed < to_remove and idx > wanted) {
                idx -= 1;
                const sid = updated_user_spaces[idx];

                // Only remove empty spaces
                const windows = Space.getWindowList(self.allocator, sid, true) catch continue;
                defer self.allocator.free(windows);
                if (windows.len > 0) {
                    log.info("space sync: keeping space {d} (has {d} windows)", .{ sid, windows.len });
                    continue;
                }

                if (sa.destroySpace(sid)) {
                    removed += 1;
                    log.info("space sync: removed empty space {d}", .{sid});
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                } else {
                    log.warn("space sync: failed to destroy space {d}", .{sid});
                    break;
                }
            }
        }

        // Re-fetch and label spaces
        std.Thread.sleep(200 * std.time.ns_per_ms); // Let macOS settle
        self.syncSpacesLabelsOnly();
    }

    /// Label spaces according to config, respecting display assignments
    fn syncSpacesLabelsOnly(self: *Self) void {
        const displays = Displays.getActiveDisplayList(self.allocator) catch return;
        defer self.allocator.free(displays);

        // Track which config spaces have been assigned
        var assigned = std.StaticBitSet(64).initEmpty();

        // First pass: assign spaces to their preferred displays
        for (displays) |did| {
            const display_spaces = Display.getSpaceList(self.allocator, did) catch continue;
            defer self.allocator.free(display_spaces);

            // Get display label (if any)
            const display_label = self.displays.getLabelForDisplay(did);

            // Filter user spaces on this display
            var user_spaces: [32]u64 = undefined;
            var user_count: usize = 0;
            for (display_spaces) |sid| {
                if (Space.isUser(sid) and user_count < 32) {
                    user_spaces[user_count] = sid;
                    user_count += 1;
                }
            }

            // Find config spaces that belong to this display
            var space_idx: usize = 0;
            for (self.config.spaces.items, 0..) |space_cfg, cfg_idx| {
                if (space_idx >= user_count) break;
                if (cfg_idx >= 64 or assigned.isSet(cfg_idx)) continue;

                // Check if this space belongs to this display
                const belongs_here = blk: {
                    if (space_cfg.display) |target_display| {
                        // Space has explicit display assignment
                        if (display_label) |label| {
                            break :blk std.mem.eql(u8, target_display, label);
                        }
                        break :blk false; // Display has no label, can't match
                    }
                    // No display specified - only assign if no displays are configured
                    break :blk self.config.displays.items.len == 0;
                };

                if (belongs_here) {
                    const sid = user_spaces[space_idx];
                    // Only set label if it changed
                    const current_label = self.spaces.getLabelForSpace(sid);
                    if (current_label == null or !std.mem.eql(u8, current_label.?, space_cfg.name)) {
                        self.spaces.setLabel(sid, space_cfg.name) catch {};
                        log.info("space sync: labeled space {d} as '{s}' (display {?s})", .{ sid, space_cfg.name, display_label });
                    }
                    assigned.set(cfg_idx);
                    space_idx += 1;
                }
            }
        }

        // Second pass: assign remaining config spaces to remaining unlabeled macOS spaces
        // This handles the case where a display is disconnected but we still want rules to work
        const all_spaces = self.getAllSpaceIds() orelse return;
        defer self.allocator.free(all_spaces);

        var fallback_idx: usize = 0;
        for (self.config.spaces.items, 0..) |space_cfg, cfg_idx| {
            if (cfg_idx >= 64 or assigned.isSet(cfg_idx)) continue;

            // Find next unlabeled user space
            while (fallback_idx < all_spaces.len) {
                const sid = all_spaces[fallback_idx];
                fallback_idx += 1;
                if (!Space.isUser(sid)) continue;
                if (self.spaces.getLabelForSpace(sid) != null) continue;

                // Found an unlabeled space - assign this config space to it
                self.spaces.setLabel(sid, space_cfg.name) catch {};
                assigned.set(cfg_idx);
                log.info("space sync: labeled space {d} as '{s}' (fallback)", .{ sid, space_cfg.name });
                break;
            }
        }
    }

    /// Scan all running applications and set up observers
    fn scanRunningApplications(self: *Self) void {
        const workspace = @import("platform/workspace.zig");
        const pids = workspace.getRunningAppPids(self.allocator, self.pid) catch return;
        defer self.allocator.free(pids);

        log.info("scanning {d} running applications", .{pids.len});

        var tracked: usize = 0;
        for (pids) |pid| {
            self.addApplicationWithPid(pid);
            tracked += 1;
        }

        log.info("tracked {d} applications", .{tracked});

        // Apply layout to ALL spaces with windows (not just visible)
        self.applyAllSpaceLayouts();
    }

    /// Apply layout to visible spaces (current space on each display)
    fn applyAllSpaceLayouts(self: *Self) void {
        // Get all active displays
        const displays = Displays.getActiveDisplayList(self.allocator) catch return;
        defer self.allocator.free(displays);

        // Apply layout to the current space on each display
        for (displays) |did| {
            const sid = Display.getCurrentSpace(did) orelse continue;
            const bounds = self.getBoundsForSpace(sid) orelse continue;

            self.spaces.applyLayout(sid, bounds, &self.windows) catch |err| {
                log.warn("applyAllSpaceLayouts: failed for space {}: {}", .{ sid, err });
                continue;
            };
            log.info("applied layout to space {}", .{sid});
        }

        // Wait for macOS/apps to settle, then apply again
        std.Thread.sleep(200 * std.time.ns_per_ms);
        log.debug("applyAllSpaceLayouts: second pass after delay", .{});

        for (displays) |did| {
            const sid = Display.getCurrentSpace(did) orelse continue;
            const bounds = self.getBoundsForSpace(sid) orelse continue;

            self.spaces.applyLayout(sid, bounds, &self.windows) catch |err| {
                log.warn("applyAllSpaceLayouts: second pass failed for space {}: {}", .{ sid, err });
            };
        }
    }

    /// Add an application to tracking and start observing
    fn addApplicationWithPid(self: *Self, pid: c.pid_t) void {
        // Check if already tracked
        if (self.apps.getApplication(pid) != null) return;

        // Create AX element for app
        const ax_ref = ax.createApplicationElement(pid);
        if (ax_ref == null) return;

        // Create observer
        const observer = ax.createObserver(pid, axObserverCallback) catch {
            c.c.CFRelease(ax_ref);
            return;
        };

        // Subscribe to notifications
        ax.observerAddNotification(observer, ax_ref, ax.Notification.window_created, null) catch {};
        ax.observerAddNotification(observer, ax_ref, ax.Notification.focused_window_changed, null) catch {};
        ax.observerAddNotification(observer, ax_ref, ax.Notification.window_minimized, null) catch {};
        ax.observerAddNotification(observer, ax_ref, ax.Notification.window_deminimized, null) catch {};

        // Add to run loop
        const source = ax.observerGetRunLoopSource(observer);
        c.c.CFRunLoopAddSource(c.c.CFRunLoopGetMain(), source, c.c.kCFRunLoopDefaultMode);

        // Track it
        self.apps.addApplication(.{
            .pid = pid,
            .ax_ref = ax_ref,
            .observer = observer,
            .is_observing = true,
        }) catch {
            c.c.CFRunLoopRemoveSource(c.c.CFRunLoopGetMain(), source, c.c.kCFRunLoopDefaultMode);
            c.c.CFRelease(observer);
            c.c.CFRelease(ax_ref);
            return;
        };

        // Add existing windows to layout and observe them
        self.addApplicationWindows(pid, ax_ref, observer);

        var name_buf: [256]u8 = undefined;
        const name_len = c.c.proc_name(pid, &name_buf, 256);
        const app_name = if (name_len > 0) name_buf[0..@intCast(name_len)] else "unknown";
        log.debug("tracking app: {s} (pid={d})", .{ app_name, pid });
    }

    /// Add all windows from an application to the layout (each to its own space)
    fn addApplicationWindows(self: *Self, pid: c.pid_t, ax_ref: c.AXUIElementRef, observer: c.c.AXObserverRef) void {
        // Get app name for rule matching
        var app_name_buf: [256]u8 = undefined;
        const name_len = c.c.proc_name(pid, &app_name_buf, 256);
        const app_name: ?[]const u8 = if (name_len > 0) app_name_buf[0..@intCast(name_len)] else null;

        // Get window list
        const windows = Application.getWindowList(ax_ref) orelse return;
        defer c.c.CFRelease(windows);

        const count: usize = @intCast(c.c.CFArrayGetCount(windows));
        for (0..count) |i| {
            const win_ref: c.AXUIElementRef = @ptrCast(@constCast(c.c.CFArrayGetValueAtIndex(windows, @intCast(i))));
            if (win_ref == null) continue;

            // Get window ID
            const wid = Application.getWindowId(win_ref) orelse continue;

            // Get the space this window is actually on
            var space_id = Window.getSpace(wid);
            if (space_id == 0) continue;

            // Apply rules to determine if managed and target space
            var should_manage = self.shouldManageWindow(win_ref);
            if (app_name) |name| {
                const rules = self.config.findMatchingRules(name, null, self.allocator) catch &[_]*const Config.AppRule{};
                defer if (rules.len > 0) self.allocator.free(rules);

                for (rules) |rule| {
                    // Override manage flag from rule
                    if (rule.manage) |manage| {
                        should_manage = manage;
                    }

                    // Move to named space if specified
                    if (rule.space) |space_name| {
                        if (self.resolveSpaceName(space_name)) |target_space| {
                            if (target_space != space_id) {
                                if (self.moveWindowToSpaceInternal(wid, target_space)) {
                                    log.info("rule: moved {s} window {} to space {s}", .{ name, wid, space_name });
                                    space_id = target_space;
                                } else {
                                    log.warn("failed to move wid={} to space {s}", .{ wid, space_name });
                                }
                            }
                        }
                    }

                    // Apply opacity
                    if (rule.opacity) |opacity| {
                        Window.setOpacity(wid, opacity) catch {};
                    }

                    // Apply layer
                    if (rule.layer) |layer| {
                        const level: i32 = switch (layer) {
                            .below => self.layer_below,
                            .normal => self.layer_normal,
                            .above => self.layer_above,
                        };
                        Window.setLevel(wid, level) catch {};
                    }
                }
            }

            if (!should_manage) continue;

            // Observe window destruction - pass wid as context since element is invalid when destroyed
            const wid_ptr: ?*anyopaque = @ptrFromInt(wid);
            ax.observerAddNotification(observer, win_ref, ax.Notification.element_destroyed, wid_ptr) catch {};

            // Track in Windows (central authority for window→space mapping)
            // Retain the AX ref since we're storing it
            _ = c.c.CFRetain(win_ref);
            self.windows.addWindow(.{
                .id = wid,
                .pid = pid,
                .space_id = space_id,
                .ax_ref = win_ref,
            }) catch {
                c.c.CFRelease(win_ref);
                continue;
            };
        }
    }

    /// Resolve a named space to a space ID
    /// First checks Spaces labels (set by profiles), then falls back to config order
    fn resolveSpaceName(self: *Self, name: []const u8) ?u64 {
        // First: check if a profile has assigned this name to a specific space
        if (self.spaces.getSpaceForLabel(name)) |sid| {
            return sid;
        }

        // Fallback: map named spaces from config to macOS spaces by order
        for (self.config.spaces.items, 0..) |space, idx| {
            if (std.mem.eql(u8, space.name, name)) {
                // Map to actual macOS space by index (1-based)
                return self.spaceIdFromIndex(idx + 1);
            }
        }
        return null;
    }

    /// Check if a window should be managed (tiled)
    fn shouldManageWindow(_: *Self, win_ref: c.AXUIElementRef) bool {

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

    /// Remove an application from tracking
    fn removeApplicationWithPid(self: *Self, pid: c.pid_t) void {
        _ = self.apps.removeApplication(pid);
        log.debug("stopped tracking app pid={d}", .{pid});
    }

    /// AX Observer callback - called from run loop when window events occur
    fn axObserverCallback(
        observer: c.c.AXObserverRef,
        element: c.AXUIElementRef,
        notification: c.CFStringRef,
        refcon: ?*anyopaque,
    ) callconv(.c) void {
        const self = instance orelse return;

        // Check if shutting down
        if (self.shutting_down.load(.acquire)) return;

        // Create CFStrings for comparison
        const created = ax.createCFString(ax.Notification.window_created);
        defer c.c.CFRelease(created);
        const minimized = ax.createCFString(ax.Notification.window_minimized);
        defer c.c.CFRelease(minimized);
        const deminimized = ax.createCFString(ax.Notification.window_deminimized);
        defer c.c.CFRelease(deminimized);
        const destroyed = ax.createCFString(ax.Notification.element_destroyed);
        defer c.c.CFRelease(destroyed);
        const focus_changed = ax.createCFString(ax.Notification.focused_window_changed);
        defer c.c.CFRelease(focus_changed);

        if (c.c.CFStringCompare(notification, created, 0) == c.c.kCFCompareEqualTo) {
            // Window created - apply rules and add to layout
            const wid = Application.getWindowId(element) orelse {
                log.debug("window created: could not get wid", .{});
                return;
            };

            log.debug("window created notification: wid={d}", .{wid});

            // Get pid and app name for rule matching
            const pid = ax.getPid(element) catch {
                log.debug("window created: wid={d} could not get pid", .{wid});
                return;
            };
            var app_name_buf: [256]u8 = undefined;
            const name_len = c.c.proc_name(pid, &app_name_buf, 256);
            const app_name: ?[]const u8 = if (name_len > 0) app_name_buf[0..@intCast(name_len)] else null;

            // Get window's current space
            var space_id = Window.getSpace(wid);
            if (space_id == 0) space_id = self.getCurrentSpaceId() orelse return;

            // Apply rules to determine management and target space
            var should_manage = self.shouldManageWindow(element);
            if (app_name) |name| {
                const rules = self.config.findMatchingRules(name, null, self.allocator) catch &[_]*const Config.AppRule{};
                defer if (rules.len > 0) self.allocator.free(rules);

                for (rules) |rule| {
                    if (rule.manage) |manage| {
                        should_manage = manage;
                    }

                    if (rule.space) |space_name| {
                        if (self.resolveSpaceName(space_name)) |target_space| {
                            if (target_space != space_id) {
                                if (self.moveWindowToSpaceInternal(wid, target_space)) {
                                    log.info("rule: moved new {s} window {} to space {s}", .{ name, wid, space_name });
                                    space_id = target_space;
                                } else {
                                    log.warn("failed to move new window {} to space {s}", .{ wid, space_name });
                                }
                            }
                        }
                    }

                    if (rule.opacity) |opacity| {
                        Window.setOpacity(wid, opacity) catch {};
                    }

                    if (rule.layer) |layer| {
                        const level: i32 = switch (layer) {
                            .below => self.layer_below,
                            .normal => self.layer_normal,
                            .above => self.layer_above,
                        };
                        Window.setLevel(wid, level) catch {};
                    }
                }
            }

            if (!should_manage) {
                log.debug("window created: wid={d} not managed (rule)", .{wid});
                return;
            }

            // Observe window destruction - pass wid as context since element is invalid when destroyed
            const wid_ptr: ?*anyopaque = @ptrFromInt(wid);
            ax.observerAddNotification(observer, element, ax.Notification.element_destroyed, wid_ptr) catch |e| {
                log.debug("window created: wid={d} failed to observe destruction: {}", .{ wid, e });
            };

            // Track in Windows
            _ = c.c.CFRetain(element);
            self.windows.addWindow(.{
                .id = wid,
                .pid = pid,
                .space_id = space_id,
                .ax_ref = element,
            }) catch {
                c.c.CFRelease(element);
                return;
            };

            // Apply layout to the target space directly, with retries
            // (Apps like iTerm2 may revert window frames shortly after creation)
            if (self.getBoundsForSpace(space_id)) |bounds| {
                // Try multiple times with increasing delays
                for (0..3) |attempt| {
                    self.spaces.applyLayout(space_id, bounds, &self.windows) catch {};
                    const delay: u64 = (attempt + 1) * 150 * std.time.ns_per_ms;
                    std.Thread.sleep(delay);
                }
                // Final apply
                self.spaces.applyLayout(space_id, bounds, &self.windows) catch |err| {
                    log.err("window created: layout failed for space {}: {}", .{ space_id, err });
                };
            }

            log.info("window created: wid={d} added to space {d}", .{ wid, space_id });
        } else if (c.c.CFStringCompare(notification, destroyed, 0) == c.c.kCFCompareEqualTo) {
            // Window destroyed - get wid from refcon since element is now invalid
            const wid: u32 = @intCast(@intFromPtr(refcon));
            log.debug("window destroyed notification: wid={d} (from refcon)", .{wid});

            if (wid == 0) return;

            // Lookup space from Windows (avoids querying invalid window)
            const space_id = if (self.windows.getWindow(wid)) |win_info|
                win_info.space_id
            else
                self.getCurrentSpaceId() orelse return;

            _ = self.windows.removeWindow(wid);
            self.applyLayoutToSpace(space_id);
            log.debug("window destroyed: wid={d} removed", .{wid});
        } else if (c.c.CFStringCompare(notification, minimized, 0) == c.c.kCFCompareEqualTo) {
            // Window minimized - update flag (layout will exclude it)
            const wid = Application.getWindowId(element) orelse return;

            // Update minimized flag in Windows
            self.windows.setMinimized(wid, true);

            // Apply layout (minimized windows will be excluded by getTileableWindowsForSpace)
            self.applyCurrentLayout();

            log.debug("window minimized: wid={d}", .{wid});
        } else if (c.c.CFStringCompare(notification, deminimized, 0) == c.c.kCFCompareEqualTo) {
            // Window deminimized - update flag and re-layout
            const wid = Application.getWindowId(element) orelse return;

            if (!self.shouldManageWindow(element)) return;

            // Update minimized flag in Windows
            self.windows.setMinimized(wid, false);

            // Get current space from Windows
            const space_id = self.windows.getWindowSpace(wid) orelse self.getCurrentSpaceId() orelse return;

            self.applyLayoutToSpace(space_id);

            log.debug("window deminimized: wid={d} space={d}", .{ wid, space_id });
        } else if (c.c.CFStringCompare(notification, focus_changed, 0) == c.c.kCFCompareEqualTo) {
            // Window focus changed - update tracking and handle mouse warp
            const wid = Application.getWindowId(element) orelse return;

            // Update focused window tracking
            self.windows.setFocused(wid);

            // Check if this focus was triggered by FFM
            const was_ffm = (self.ffm_window_id == wid);

            // Clear the one-shot FFM flag (focus is now confirmed)
            self.ffm_window_id = 0;

            if (was_ffm) {
                // FFM caused this focus - cursor is already on the window, skip warp
                log.debug("focus changed: wid={d} (ffm confirmed)", .{wid});
                return;
            }

            // Non-FFM focus (keyboard shortcut, Cmd+Tab, click) - warp mouse if enabled
            if (self.config.mouse_follows_focus) {
                self.warpMouseToWindow(wid);
                log.debug("focus changed: wid={d} (mouse warped)", .{wid});
            }
        }
    }

    /// Handle application front switched (Cmd+Tab, click on app, etc.)
    fn handleApplicationFrontSwitched(self: *Self, pid: c.pid_t) void {
        // Get the app's focused window
        if (self.apps.getApplication(pid)) |app| {
            if (Application.getFocusedWindow(app.ax_ref)) |win_ref| {
                defer c.c.CFRelease(win_ref);
                if (Application.getWindowId(win_ref)) |wid| {
                    // Update tracking
                    self.windows.setFocused(wid);

                    // Check if FFM caused this switch
                    const was_ffm = (self.ffm_window_id == wid);
                    self.ffm_window_id = 0; // Clear one-shot flag

                    if (was_ffm) {
                        log.debug("app front switched: pid={d} wid={d} (ffm confirmed)", .{ pid, wid });
                        return;
                    }

                    // Non-FFM switch - warp mouse if enabled
                    if (self.config.mouse_follows_focus) {
                        log.debug("app front switched: pid={d} focused wid={d}", .{ pid, wid });
                        self.warpMouseToWindow(wid);
                    }
                    return;
                }
            }
        }
        log.debug("app front switched: pid={d} (not tracked or no window)", .{pid});
    }

    /// Handle application launched event
    pub fn handleApplicationLaunched(self: *Self, pid: c.pid_t) void {
        self.addApplicationWithPid(pid);
        self.applyCurrentLayout();
    }

    /// Handle application terminated event
    pub fn handleApplicationTerminated(self: *Self, pid: c.pid_t) void {
        // Remove all windows for this PID from Windows
        const removed = self.windows.removeWindowsForPid(pid);
        if (removed > 0) {
            log.debug("app terminated: removed {d} windows for pid={d}", .{ removed, pid });
        }

        // Remove app from tracking
        self.removeApplicationWithPid(pid);

        // Apply layout to current space
        self.applyCurrentLayout();
    }

    /// Handle application hidden event - mark windows as hidden for layout exclusion
    fn handleApplicationHidden(self: *Self, pid: c.pid_t) void {
        // Mark all windows for this PID as hidden
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pid == pid) {
                entry.value_ptr.flags.hidden = true;
            }
        }
        self.applyCurrentLayout();
    }

    /// Handle application visible event - mark windows as visible and re-layout
    fn handleApplicationVisible(self: *Self, pid: c.pid_t) void {
        // Mark all windows for this PID as visible
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pid == pid) {
                entry.value_ptr.flags.hidden = false;
            }
        }
        self.applyCurrentLayout();
    }

    /// Handle space changed event - switch to new space's layout
    fn handleSpaceChanged(self: *Self) void {
        // Update current space tracking
        if (self.getCurrentSpaceId()) |sid| {
            self.spaces.setCurrentSpace(sid);
        }
        // Apply layout for the now-visible space
        self.applyCurrentLayout();
    }

    /// Handle active display changed event (focus moved between displays)
    /// Note: This is NOT for display add/remove - that's handled by displayReconfigurationCallback
    fn handleDisplayChanged(self: *Self) void {
        // Just reapply layout for the current space on the now-active display
        self.applyCurrentLayout();
    }

    /// Handle system wake event - rescan and rebuild everything
    fn handleSystemWoke(self: *Self) void {
        // After wake, windows may have moved or apps may have changed state
        // Do a full rescan
        self.scanRunningApplications();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Daemon path formatting" {
    // Can't fully test without proper environment, but we can test the struct exists
    const d = Daemon{
        .allocator = std.testing.allocator,
        .skylight = undefined,
    };
    _ = d;
}
