///! Command execution handler for typed IPC commands
///!
///! This module bridges parsed Message.Command types to actual Daemon operations.
///! It provides type-safe command execution with consistent error handling.
const std = @import("std");
const posix = std.posix;

const Message = @import("Message.zig");
const Server = @import("Server.zig");
const Response = @import("Response.zig");
const QueryHandler = @import("QueryHandler.zig");

const c = @import("../platform/c.zig");
const skylight = @import("../platform/skylight.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Display = @import("../core/Display.zig");
const View = @import("../core/View.zig");
const Layout = @import("../core/Layout.zig");
const geometry = @import("../core/geometry.zig");
const Windows = @import("../state/Windows.zig");
const Spaces = @import("../state/Spaces.zig");
const Displays = @import("../state/Displays.zig");
const Config = @import("../config/Config.zig");

const log = std.log.scoped(.command);

/// Execution context - provides access to daemon state
pub const Context = struct {
    allocator: std.mem.Allocator,
    skylight: *const skylight.SkyLight,
    connection: c_int,
    windows: *Windows,
    spaces: *Spaces,
    displays: *Displays,
    config: *Config,

    // Callbacks for operations that need daemon-level access
    applyLayout: *const fn (ctx: *Context, space_id: u64) void,
    getBoundsForSpace: *const fn (ctx: *Context, space_id: u64) ?geometry.Rect,
};

/// Result of command execution
pub const Result = union(enum) {
    /// Command succeeded with optional response data
    ok: []const u8,
    /// Command failed with error
    err: Response.Error,
};

/// Execute a parsed command
pub fn execute(ctx: *Context, cmd: Message.Command) Result {
    return switch (cmd) {
        // Window commands
        .window_focus => |sel| windowFocus(ctx, sel),
        .window_close => |sel| windowClose(ctx, sel),
        .window_minimize => |sel| windowMinimize(ctx, sel),
        .window_swap => |s| windowSwap(ctx, s.src, s.dst),
        .window_warp => |s| windowWarp(ctx, s.src, s.dst),
        .window_space => |s| windowSpace(ctx, s.window, s.space),
        .window_toggle => |t| windowToggle(ctx, t.window, t.prop),

        // Space commands
        .space_focus => |sel| spaceFocus(ctx, sel),
        .space_layout => |s| spaceLayout(ctx, s.space, s.layout),
        .space_balance => |sel| spaceBalance(ctx, sel),
        .space_label => |s| spaceLabel(ctx, s.space, s.label),

        // Display commands
        .display_focus => |sel| displayFocus(ctx, sel),

        // Query commands - delegate to QueryHandler
        .query_windows => |q| queryWindows(ctx, q.space, q.display),
        .query_spaces => |q| querySpaces(ctx, q.display),
        .query_displays => queryDisplays(ctx),

        // Config commands
        .config_get => |key| configGet(ctx, key),
        .config_set => |s| configSet(ctx, s.key, s.value),

        // Not yet implemented
        .window_deminimize,
        .window_stack,
        .window_display,
        .window_move,
        .window_resize,
        .window_ratio,
        .window_opacity,
        .window_layer,
        .window_insert,
        .window_grid,
        .space_create,
        .space_destroy,
        .space_move,
        .space_swap,
        .space_display,
        .space_padding,
        .space_gap,
        .space_mirror,
        .space_rotate,
        .space_toggle,
        .display_space,
        .display_label,
        .rule_add,
        .rule_remove,
        .rule_list,
        .signal_add,
        .signal_remove,
        .signal_list,
        => .{ .err = Response.errWithDetail(.unknown_command, "not implemented") },
    };
}

// ============================================================================
// Window Commands
// ============================================================================

fn windowFocus(ctx: *Context, sel: Message.WindowSelector) Result {
    const wid = resolveWindow(ctx, sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };

    // Try to use cached ax_ref from tracked window
    if (ctx.windows.getWindow(wid)) |tracked| {
        if (tracked.ax_ref != null) {
            // Bring app to front
            var psn: c.c.ProcessSerialNumber = undefined;
            if (c.c.GetProcessForPID(tracked.pid, &psn) == 0) {
                _ = c.c.SetFrontProcessWithOptions(&psn, c.c.kSetFrontProcessFrontWindowOnly);
            }

            // Use cached ax_ref to focus
            const kAXRaiseAction = c.cfstr("AXRaise");
            defer c.c.CFRelease(kAXRaiseAction);
            const kAXMainAttribute = c.cfstr("AXMain");
            defer c.c.CFRelease(kAXMainAttribute);

            _ = c.c.AXUIElementPerformAction(tracked.ax_ref, kAXRaiseAction);
            _ = c.c.AXUIElementSetAttributeValue(tracked.ax_ref, kAXMainAttribute, c.c.kCFBooleanTrue);
            warpMouseToWindow(ctx, wid);
            return .{ .ok = "" };
        }
    }

    // Fallback: window not tracked, use SkyLight lookup
    const sl = ctx.skylight;
    const cid = ctx.connection;

    var owner_cid: c_int = 0;
    if (sl.SLSGetWindowOwner(cid, wid, &owner_cid) != 0) {
        return .{ .err = Response.err(.window_not_found) };
    }

    var pid: c.pid_t = 0;
    _ = sl.SLSConnectionGetPID(owner_cid, &pid);

    // Get PSN for the process
    var psn: c.c.ProcessSerialNumber = undefined;
    if (sl.SLSGetConnectionPSN(owner_cid, &psn) != 0) {
        return .{ .err = Response.err(.skylight_error) };
    }

    // Bring app to front
    _ = c.c.SetFrontProcessWithOptions(&psn, c.c.kSetFrontProcessFrontWindowOnly);

    // Use AX to focus the specific window
    const app = c.c.AXUIElementCreateApplication(pid);
    if (app == null) {
        return .{ .err = Response.err(.ax_error) };
    }
    defer c.c.CFRelease(app);

    // Get all windows
    var windows_ref: c.c.CFTypeRef = null;
    const kAXWindowsAttribute = c.cfstr("AXWindows");
    defer c.c.CFRelease(kAXWindowsAttribute);
    if (c.c.AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows_ref) != 0) {
        return .{ .err = Response.err(.ax_error) };
    }
    defer c.c.CFRelease(windows_ref);

    const windows: c.c.CFArrayRef = @ptrCast(windows_ref);
    const count = c.c.CFArrayGetCount(windows);

    // Find window with matching ID and raise it
    const kAXRaiseAction = c.cfstr("AXRaise");
    defer c.c.CFRelease(kAXRaiseAction);
    const kAXMainAttribute = c.cfstr("AXMain");
    defer c.c.CFRelease(kAXMainAttribute);

    var i: c.c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const win = c.c.CFArrayGetValueAtIndex(windows, i);
        const ax_win: c.c.AXUIElementRef = @ptrCast(@constCast(win));

        // Get CGWindowID for this AX window
        var win_id: u32 = 0;
        if (c._AXUIElementGetWindow(ax_win, &win_id) == 0 and win_id == wid) {
            // Raise and focus this window
            _ = c.c.AXUIElementPerformAction(ax_win, kAXRaiseAction);
            _ = c.c.AXUIElementSetAttributeValue(ax_win, kAXMainAttribute, c.c.kCFBooleanTrue);
            warpMouseToWindow(ctx, wid);
            break;
        }
    }

    return .{ .ok = "" };
}

fn windowSwap(ctx: *Context, src_sel: Message.WindowSelector, dst_sel: Message.WindowSelector) Result {
    const src_wid = resolveWindow(ctx, src_sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };
    const dst_wid = resolveWindow(ctx, dst_sel) orelse {
        return .{ .err = Response.errWithDetail(.window_not_found, "target") };
    };

    if (src_wid == dst_wid) {
        return .{ .ok = "" };
    }

    // Use tracked space_id from source window, fallback to current space
    const space_id = if (ctx.windows.getWindow(src_wid)) |w| w.space_id else getCurrentSpaceId(ctx) orelse {
        return .{ .err = Response.err(.no_focused_space) };
    };

    // Swap windows by swapping their positions in WindowTable's ordering
    ctx.windows.swapWindowOrder(src_wid, dst_wid);
    ctx.applyLayout(ctx, space_id);

    return .{ .ok = "" };
}

fn windowWarp(ctx: *Context, src_sel: Message.WindowSelector, dst_sel: Message.WindowSelector) Result {
    const src_wid = resolveWindow(ctx, src_sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };
    const dst_wid = resolveWindow(ctx, dst_sel) orelse {
        return .{ .err = Response.errWithDetail(.window_not_found, "target") };
    };

    if (src_wid == dst_wid) {
        return .{ .ok = "" };
    }

    // Use tracked space_id from source window, fallback to current space
    const space_id = if (ctx.windows.getWindow(src_wid)) |w| w.space_id else getCurrentSpaceId(ctx) orelse {
        return .{ .err = Response.err(.no_focused_space) };
    };

    const view = ctx.spaces.views.get(space_id) orelse {
        return .{ .err = Response.err(.space_not_found) };
    };

    Layout.warpWindow(view, src_wid, dst_wid) catch {
        return .{ .err = Response.err(.skylight_error) };
    };

    ctx.applyLayout(ctx, space_id);

    return .{ .ok = "" };
}

fn windowSpace(ctx: *Context, win_sel: Message.WindowSelector, space_sel: Message.SpaceSelector) Result {
    const wid = resolveWindow(ctx, win_sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };

    const target_space = resolveSpace(ctx, space_sel) orelse {
        return .{ .err = Response.errWithDetail(.invalid_selector, "space") };
    };

    // Get current space for the window
    const current_space = if (ctx.windows.getWindow(wid)) |win|
        win.space_id
    else
        getCurrentSpaceId(ctx) orelse return .{ .err = Response.err(.space_not_found) };

    if (current_space == target_space) {
        return .{ .ok = "" };
    }

    // Move window to target space
    Space.moveWindows(&[_]u32{wid}, target_space) catch {
        return .{ .err = Response.err(.skylight_error) };
    };

    // Update windows tracking
    ctx.windows.setWindowSpace(wid, target_space);

    // Apply layouts to both spaces
    ctx.applyLayout(ctx, current_space);
    ctx.applyLayout(ctx, target_space);

    log.info("moved window {} to space {}", .{ wid, target_space });
    return .{ .ok = "" };
}

fn windowToggle(ctx: *Context, sel: Message.WindowSelector, prop: Message.WindowToggle) Result {
    const wid = resolveWindow(ctx, sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };

    return switch (prop) {
        .float => toggleFloat(ctx, wid),
        .zoom_fullscreen => .{ .err = Response.errWithDetail(.unknown_command, "zoom not implemented") },
        else => .{ .err = Response.err(.invalid_argument) },
    };
}

fn toggleFloat(ctx: *Context, wid: Window.Id) Result {
    const win = ctx.windows.getWindow(wid) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };

    // Use tracked space_id
    const space_id = win.space_id;

    // Toggle the floating flag
    win.flags.floating = !win.flags.floating;

    // Apply layout (floating windows will be excluded by getTileableWindowsForSpace)
    ctx.applyLayout(ctx, space_id);

    log.info("window {} float={}", .{ wid, win.flags.floating });
    return .{ .ok = "" };
}

fn windowClose(ctx: *Context, sel: Message.WindowSelector) Result {
    const wid = resolveWindow(ctx, sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };

    const kAXCloseButtonAttribute = c.cfstr("AXCloseButton");
    defer c.c.CFRelease(kAXCloseButtonAttribute);
    const kAXPressAction = c.cfstr("AXPress");
    defer c.c.CFRelease(kAXPressAction);

    // Try to use cached ax_ref from tracked window
    if (ctx.windows.getWindow(wid)) |tracked| {
        if (tracked.ax_ref != null) {
            var close_button_ref: c.c.CFTypeRef = null;
            if (c.c.AXUIElementCopyAttributeValue(tracked.ax_ref, kAXCloseButtonAttribute, &close_button_ref) == 0) {
                defer c.c.CFRelease(close_button_ref);
                const close_button: c.c.AXUIElementRef = @ptrCast(close_button_ref);
                _ = c.c.AXUIElementPerformAction(close_button, kAXPressAction);
                return .{ .ok = "" };
            }
        }
    }

    // Fallback: window not tracked, use SkyLight lookup
    const sl = ctx.skylight;
    const cid = ctx.connection;

    var owner_cid: c_int = 0;
    if (sl.SLSGetWindowOwner(cid, wid, &owner_cid) != 0) {
        return .{ .err = Response.err(.window_not_found) };
    }

    var pid: c.pid_t = 0;
    _ = sl.SLSConnectionGetPID(owner_cid, &pid);

    const app = c.c.AXUIElementCreateApplication(pid);
    if (app == null) {
        return .{ .err = Response.err(.ax_error) };
    }
    defer c.c.CFRelease(app);

    var windows_ref: c.c.CFTypeRef = null;
    const kAXWindowsAttribute = c.cfstr("AXWindows");
    defer c.c.CFRelease(kAXWindowsAttribute);
    if (c.c.AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows_ref) != 0) {
        return .{ .err = Response.err(.ax_error) };
    }
    defer c.c.CFRelease(windows_ref);

    const windows: c.c.CFArrayRef = @ptrCast(windows_ref);
    const count = c.c.CFArrayGetCount(windows);

    var i: c.c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const win = c.c.CFArrayGetValueAtIndex(windows, i);
        const ax_win: c.c.AXUIElementRef = @ptrCast(@constCast(win));

        var win_id: u32 = 0;
        if (c._AXUIElementGetWindow(ax_win, &win_id) == 0 and win_id == wid) {
            var close_button_ref: c.c.CFTypeRef = null;
            if (c.c.AXUIElementCopyAttributeValue(ax_win, kAXCloseButtonAttribute, &close_button_ref) == 0) {
                defer c.c.CFRelease(close_button_ref);
                const close_button: c.c.AXUIElementRef = @ptrCast(close_button_ref);
                _ = c.c.AXUIElementPerformAction(close_button, kAXPressAction);
                return .{ .ok = "" };
            }
            break;
        }
    }

    return .{ .err = Response.err(.ax_error) };
}

fn windowMinimize(ctx: *Context, sel: Message.WindowSelector) Result {
    const wid = resolveWindow(ctx, sel) orelse {
        return .{ .err = Response.err(.window_not_found) };
    };

    const kAXMinimizedAttribute = c.cfstr("AXMinimized");
    defer c.c.CFRelease(kAXMinimizedAttribute);

    // Try to use cached ax_ref from tracked window
    if (ctx.windows.getWindow(wid)) |tracked| {
        if (tracked.ax_ref != null) {
            if (c.c.AXUIElementSetAttributeValue(tracked.ax_ref, kAXMinimizedAttribute, c.c.kCFBooleanTrue) == 0) {
                return .{ .ok = "" };
            }
        }
    }

    // Fallback: window not tracked, use SkyLight lookup
    const sl = ctx.skylight;
    const cid = ctx.connection;

    var owner_cid: c_int = 0;
    if (sl.SLSGetWindowOwner(cid, wid, &owner_cid) != 0) {
        return .{ .err = Response.err(.window_not_found) };
    }

    var pid: c.pid_t = 0;
    _ = sl.SLSConnectionGetPID(owner_cid, &pid);

    const app = c.c.AXUIElementCreateApplication(pid);
    if (app == null) {
        return .{ .err = Response.err(.ax_error) };
    }
    defer c.c.CFRelease(app);

    var windows_ref: c.c.CFTypeRef = null;
    const kAXWindowsAttribute = c.cfstr("AXWindows");
    defer c.c.CFRelease(kAXWindowsAttribute);
    if (c.c.AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows_ref) != 0) {
        return .{ .err = Response.err(.ax_error) };
    }
    defer c.c.CFRelease(windows_ref);

    const windows: c.c.CFArrayRef = @ptrCast(windows_ref);
    const count = c.c.CFArrayGetCount(windows);

    var i: c.c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const win = c.c.CFArrayGetValueAtIndex(windows, i);
        const ax_win: c.c.AXUIElementRef = @ptrCast(@constCast(win));

        var win_id: u32 = 0;
        if (c._AXUIElementGetWindow(ax_win, &win_id) == 0 and win_id == wid) {
            if (c.c.AXUIElementSetAttributeValue(ax_win, kAXMinimizedAttribute, c.c.kCFBooleanTrue) == 0) {
                return .{ .ok = "" };
            }
            break;
        }
    }

    return .{ .err = Response.err(.ax_error) };
}

// ============================================================================
// Space Commands
// ============================================================================

fn spaceFocus(ctx: *Context, sel: Message.SpaceSelector) Result {
    const space_id = resolveSpace(ctx, sel) orelse {
        return .{ .err = Response.err(.invalid_selector) };
    };

    const sl = ctx.skylight;
    const cid = ctx.connection;

    const display_uuid = sl.SLSCopyManagedDisplayForSpace(cid, space_id);
    if (display_uuid == null) {
        return .{ .err = Response.err(.display_not_found) };
    }
    defer c.c.CFRelease(display_uuid);

    _ = sl.SLSManagedDisplaySetCurrentSpace(cid, display_uuid, space_id);

    // Warp mouse to a window on the space, or to display center
    if (ctx.config.mouse_follows_focus) {
        const windows = ctx.windows.getTileableWindowsForSpace(ctx.allocator, space_id) catch null;
        if (windows) |wins| {
            defer ctx.allocator.free(wins);
            if (wins.len > 0) {
                warpMouseToWindow(ctx, wins[0]);
                return .{ .ok = "" };
            }
        }
        // No window found, warp to display center
        const did = Display.getId(display_uuid);
        if (did != 0) {
            warpMouseToDisplay(ctx, did);
        }
    }

    return .{ .ok = "" };
}

fn spaceLayout(ctx: *Context, sel: Message.SpaceSelector, layout: View.Layout) Result {
    const space_id = resolveSpace(ctx, sel) orelse {
        return .{ .err = Response.err(.no_focused_space) };
    };

    const view = ctx.spaces.getOrCreateView(space_id) catch {
        return .{ .err = Response.err(.space_not_found) };
    };

    view.layout = layout;
    ctx.applyLayout(ctx, space_id);

    return .{ .ok = "" };
}

fn spaceBalance(ctx: *Context, sel: Message.SpaceSelector) Result {
    const space_id = resolveSpace(ctx, sel) orelse {
        return .{ .err = Response.err(.no_focused_space) };
    };

    if (ctx.spaces.views.get(space_id)) |view| {
        view.balance();
        ctx.applyLayout(ctx, space_id);
    }

    return .{ .ok = "" };
}

fn spaceLabel(ctx: *Context, sel: Message.SpaceSelector, label: []const u8) Result {
    const space_id = resolveSpace(ctx, sel) orelse {
        return .{ .err = Response.err(.invalid_selector) };
    };

    ctx.spaces.setLabel(space_id, label) catch {
        return .{ .err = Response.err(.skylight_error) };
    };

    log.info("space {} labeled '{s}'", .{ space_id, label });
    return .{ .ok = "" };
}

// ============================================================================
// Display Commands
// ============================================================================

fn displayFocus(ctx: *Context, sel: Message.DisplaySelector) Result {
    const display_id = resolveDisplay(ctx, sel) orelse {
        return .{ .err = Response.err(.display_not_found) };
    };

    // Get current space on that display and focus it
    const space_id = Display.getCurrentSpace(display_id) orelse {
        return .{ .err = Response.err(.space_not_found) };
    };

    const sl = ctx.skylight;
    const cid = ctx.connection;

    const display_uuid = sl.SLSCopyManagedDisplayForSpace(cid, space_id);
    if (display_uuid == null) {
        return .{ .err = Response.err(.display_not_found) };
    }
    defer c.c.CFRelease(display_uuid);

    _ = sl.SLSManagedDisplaySetCurrentSpace(cid, display_uuid, space_id);

    // Warp mouse to a window on the display, or to display center
    if (ctx.config.mouse_follows_focus) {
        const windows = ctx.windows.getTileableWindowsForSpace(ctx.allocator, space_id) catch null;
        if (windows) |wins| {
            defer ctx.allocator.free(wins);
            if (wins.len > 0) {
                warpMouseToWindow(ctx, wins[0]);
                log.info("focused display {} (space {})", .{ display_id, space_id });
                return .{ .ok = "" };
            }
        }
        warpMouseToDisplay(ctx, display_id);
    }

    log.info("focused display {} (space {})", .{ display_id, space_id });
    return .{ .ok = "" };
}

fn resolveDisplay(ctx: *Context, sel: Message.DisplaySelector) ?Display.Id {
    return switch (sel) {
        .id => |id| blk: {
            // Treat small numbers as display index (1-based)
            if (id < 100) {
                break :blk Displays.getDisplayByIndex(@intCast(id));
            }
            break :blk id;
        },
        .focused => Displays.getMainDisplayId(),
        .label => |_| null, // TODO: display labels
        .first => Displays.getDisplayByIndex(1),
        .last => blk: {
            const displays = Displays.getActiveDisplayList(ctx.allocator) catch break :blk null;
            defer ctx.allocator.free(displays);
            break :blk if (displays.len > 0) displays[displays.len - 1] else null;
        },
        .prev, .next => blk: {
            const current = Displays.getMainDisplayId();
            const displays = Displays.getActiveDisplayList(ctx.allocator) catch break :blk null;
            defer ctx.allocator.free(displays);
            for (displays, 0..) |did, i| {
                if (did == current) {
                    if (sel == .prev and i > 0) break :blk displays[i - 1];
                    if (sel == .next and i + 1 < displays.len) break :blk displays[i + 1];
                    break;
                }
            }
            break :blk null;
        },
        .recent => null, // TODO: track recent display
        .north, .south, .east, .west => null, // TODO: directional display selection
    };
}

// ============================================================================
// Mouse Warp Helper
// ============================================================================

/// Warp mouse cursor to center of window if mouse_follows_focus is enabled
fn warpMouseToWindow(ctx: *Context, wid: Window.Id) void {
    if (!ctx.config.mouse_follows_focus) return;

    // Get window frame
    const frame = Window.getFrame(wid) catch return;

    // Calculate center
    const center = c.CGPoint{
        .x = frame.x + frame.width / 2,
        .y = frame.y + frame.height / 2,
    };

    // Check if cursor is already inside window
    var cursor: c.CGPoint = undefined;
    if (ctx.skylight.SLSGetCurrentCursorLocation(ctx.connection, &cursor) == 0) {
        if (cursor.x >= frame.x and cursor.x <= frame.x + frame.width and
            cursor.y >= frame.y and cursor.y <= frame.y + frame.height)
        {
            return; // Already inside, don't warp
        }
    }

    // Use CGEvent-based warp for reliability
    // Dissociate mouse and cursor, warp, then re-associate
    _ = c.c.CGAssociateMouseAndMouseCursorPosition(0);
    _ = c.c.CGWarpMouseCursorPosition(center);
    _ = c.c.CGAssociateMouseAndMouseCursorPosition(1);
}

/// Warp mouse cursor to center of display
fn warpMouseToDisplay(ctx: *Context, did: Display.Id) void {
    if (!ctx.config.mouse_follows_focus) return;

    const bounds = c.c.CGDisplayBounds(did);
    const center = c.CGPoint{
        .x = bounds.origin.x + bounds.size.width / 2,
        .y = bounds.origin.y + bounds.size.height / 2,
    };

    _ = c.c.CGAssociateMouseAndMouseCursorPosition(0);
    _ = c.c.CGWarpMouseCursorPosition(center);
    _ = c.c.CGAssociateMouseAndMouseCursorPosition(1);
}

// ============================================================================
// Query Commands
// ============================================================================

fn queryWindows(ctx: *Context, space_sel: ?Message.SpaceSelector, display_sel: ?Message.DisplaySelector) Result {
    _ = space_sel;
    _ = display_sel;
    // TODO: build JSON response using ctx
    _ = ctx;
    return .{ .ok = "[]" };
}

fn querySpaces(ctx: *Context, display_sel: ?Message.DisplaySelector) Result {
    _ = display_sel;
    _ = ctx;
    return .{ .ok = "[]" };
}

fn queryDisplays(ctx: *Context) Result {
    _ = ctx;
    return .{ .ok = "[]" };
}

// ============================================================================
// Config Commands
// ============================================================================

fn configGet(ctx: *Context, key: []const u8) Result {
    _ = ctx;
    _ = key;
    // TODO: implement config get
    return .{ .err = Response.errWithDetail(.unknown_command, "config get not implemented") };
}

fn configSet(ctx: *Context, key: []const u8, value: []const u8) Result {
    if (std.mem.eql(u8, key, "layout")) {
        if (std.mem.eql(u8, value, "bsp")) {
            ctx.spaces.layout = .bsp;
        } else if (std.mem.eql(u8, value, "stack")) {
            ctx.spaces.layout = .stack;
        } else if (std.mem.eql(u8, value, "float")) {
            ctx.spaces.layout = .float;
        } else {
            return .{ .err = Response.errWithDetail(.invalid_value, "bsp, stack, float") };
        }
    } else if (std.mem.eql(u8, key, "window_gap") or std.mem.eql(u8, key, "gap")) {
        const gap = std.fmt.parseInt(i32, value, 10) catch {
            return .{ .err = Response.errWithDetail(.invalid_value, "expected integer") };
        };
        if (gap < 0) {
            return .{ .err = Response.errWithDetail(.invalid_value, "must be positive") };
        }
        ctx.spaces.window_gap = gap;
        ctx.config.window_gap = @intCast(gap);
    } else if (std.mem.eql(u8, key, "top_padding")) {
        const pad = std.fmt.parseInt(i32, value, 10) catch {
            return .{ .err = Response.errWithDetail(.invalid_value, "expected integer") };
        };
        if (pad < 0) {
            return .{ .err = Response.errWithDetail(.invalid_value, "must be positive") };
        }
        ctx.spaces.padding.top = pad;
        ctx.config.top_padding = @intCast(pad);
    } else if (std.mem.eql(u8, key, "bottom_padding")) {
        const pad = std.fmt.parseInt(i32, value, 10) catch {
            return .{ .err = Response.errWithDetail(.invalid_value, "expected integer") };
        };
        if (pad < 0) {
            return .{ .err = Response.errWithDetail(.invalid_value, "must be positive") };
        }
        ctx.spaces.padding.bottom = pad;
        ctx.config.bottom_padding = @intCast(pad);
    } else if (std.mem.eql(u8, key, "left_padding")) {
        const pad = std.fmt.parseInt(i32, value, 10) catch {
            return .{ .err = Response.errWithDetail(.invalid_value, "expected integer") };
        };
        if (pad < 0) {
            return .{ .err = Response.errWithDetail(.invalid_value, "must be positive") };
        }
        ctx.spaces.padding.left = pad;
        ctx.config.left_padding = @intCast(pad);
    } else if (std.mem.eql(u8, key, "right_padding")) {
        const pad = std.fmt.parseInt(i32, value, 10) catch {
            return .{ .err = Response.errWithDetail(.invalid_value, "expected integer") };
        };
        if (pad < 0) {
            return .{ .err = Response.errWithDetail(.invalid_value, "must be positive") };
        }
        ctx.spaces.padding.right = pad;
        ctx.config.right_padding = @intCast(pad);
    } else if (std.mem.eql(u8, key, "split_ratio")) {
        const ratio = std.fmt.parseFloat(f32, value) catch {
            return .{ .err = Response.errWithDetail(.invalid_value, "expected float") };
        };
        if (ratio < 0.1 or ratio > 0.9) {
            return .{ .err = Response.errWithDetail(.invalid_value, "must be 0.1-0.9") };
        }
        ctx.spaces.split_ratio = ratio;
    } else if (std.mem.eql(u8, key, "auto_balance")) {
        if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true")) {
            ctx.spaces.auto_balance = true;
        } else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false")) {
            ctx.spaces.auto_balance = false;
        } else {
            return .{ .err = Response.errWithDetail(.invalid_value, "on/off") };
        }
    } else {
        return .{ .err = Response.err(.unknown_command) };
    }

    // Apply layout with new settings
    if (getCurrentSpaceId(ctx)) |space_id| {
        ctx.applyLayout(ctx, space_id);
    }

    return .{ .ok = "" };
}

// ============================================================================
// Selector Resolution
// ============================================================================

fn resolveWindow(ctx: *Context, sel: Message.WindowSelector) ?Window.Id {
    return switch (sel) {
        .id => |id| if (ctx.windows.getWindow(id) != null) id else null,
        .focused => getFocusedWindowId(),
        .first => blk: {
            const windows = getVisibleWindowIds(ctx) orelse break :blk null;
            defer ctx.allocator.free(windows);
            break :blk if (windows.len > 0) windows[0] else null;
        },
        .last => blk: {
            const windows = getVisibleWindowIds(ctx) orelse break :blk null;
            defer ctx.allocator.free(windows);
            break :blk if (windows.len > 0) windows[windows.len - 1] else null;
        },
        .recent => null, // TODO: track recent window
        .north, .south, .east, .west => findWindowInDirection(ctx, sel),
        else => null,
    };
}

fn resolveSpace(ctx: *Context, sel: Message.SpaceSelector) ?Space.Id {
    return switch (sel) {
        .id => |id| blk: {
            // Treat small numbers (1-99) as Mission Control index, not raw space ID
            // Real space IDs are much larger (e.g., 12345678)
            if (id < 100) {
                break :blk Spaces.getSpaceByIndex(@intCast(id));
            }
            break :blk id;
        },
        .focused => getCurrentSpaceId(ctx),
        .label => |label| ctx.spaces.getSpaceForLabel(label),
        .prev => blk: {
            const current = getCurrentSpaceId(ctx) orelse break :blk null;
            const spaces = getAllSpaceIds(ctx) orelse break :blk null;
            defer ctx.allocator.free(spaces);
            for (spaces, 0..) |sid, i| {
                if (sid == current and i > 0) break :blk spaces[i - 1];
            }
            break :blk null;
        },
        .next => blk: {
            const current = getCurrentSpaceId(ctx) orelse break :blk null;
            const spaces = getAllSpaceIds(ctx) orelse break :blk null;
            defer ctx.allocator.free(spaces);
            for (spaces, 0..) |sid, i| {
                if (sid == current and i + 1 < spaces.len) break :blk spaces[i + 1];
            }
            break :blk null;
        },
        .first => blk: {
            const spaces = getAllSpaceIds(ctx) orelse break :blk null;
            defer ctx.allocator.free(spaces);
            break :blk if (spaces.len > 0) spaces[0] else null;
        },
        .last => blk: {
            const spaces = getAllSpaceIds(ctx) orelse break :blk null;
            defer ctx.allocator.free(spaces);
            break :blk if (spaces.len > 0) spaces[spaces.len - 1] else null;
        },
        .recent => ctx.spaces.last_space_id,
    };
}

// ============================================================================
// Helper Functions
// ============================================================================

fn getCurrentSpaceId(ctx: *Context) ?u64 {
    _ = ctx;
    const main_display = Displays.getMainDisplayId();
    return Display.getCurrentSpace(main_display);
}

fn getAllSpaceIds(ctx: *Context) ?[]u64 {
    const displays = Displays.getActiveDisplayList(ctx.allocator) catch return null;
    defer ctx.allocator.free(displays);

    var all_spaces: std.ArrayList(u64) = .empty;
    for (displays) |did| {
        const spaces = Display.getSpaceList(ctx.allocator, did) catch continue;
        defer ctx.allocator.free(spaces);
        for (spaces) |sid| {
            all_spaces.append(ctx.allocator, sid) catch continue;
        }
    }

    if (all_spaces.items.len == 0) {
        all_spaces.deinit(ctx.allocator);
        return null;
    }
    return all_spaces.toOwnedSlice(ctx.allocator) catch null;
}

fn getFocusedWindowId() ?u32 {
    const system = c.c.AXUIElementCreateSystemWide();
    if (system == null) return null;
    defer c.c.CFRelease(system);

    const kAXFocusedApplicationAttribute = c.cfstr("AXFocusedApplication");
    defer c.c.CFRelease(kAXFocusedApplicationAttribute);

    var focused_app_ref: c.c.CFTypeRef = null;
    if (c.c.AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute, &focused_app_ref) != 0) return null;
    defer c.c.CFRelease(focused_app_ref);

    const kAXFocusedWindowAttribute = c.cfstr("AXFocusedWindow");
    defer c.c.CFRelease(kAXFocusedWindowAttribute);

    const focused_app: c.c.AXUIElementRef = @ptrCast(focused_app_ref);
    var focused_win_ref: c.c.CFTypeRef = null;
    if (c.c.AXUIElementCopyAttributeValue(focused_app, kAXFocusedWindowAttribute, &focused_win_ref) != 0) return null;
    defer c.c.CFRelease(focused_win_ref);

    const focused_win: c.c.AXUIElementRef = @ptrCast(focused_win_ref);
    var wid: u32 = 0;
    if (c._AXUIElementGetWindow(focused_win, &wid) != 0) return null;

    return wid;
}

/// Find window in direction by distance calculation
fn findWindowInDirection(ctx: *Context, sel: Message.WindowSelector) ?Window.Id {
    const focused_wid = getFocusedWindowId() orelse return null;
    const frame = Window.getFrame(focused_wid) catch return null;

    // Get space from our tracked window state
    const tracked = ctx.windows.getWindow(focused_wid) orelse return null;
    const current_space = tracked.space_id;

    return findWindowInDirectionImpl(ctx, focused_wid, frame, sel, current_space);
}

/// Find nearest window in direction by distance calculation
fn findWindowInDirectionImpl(ctx: *Context, focused_wid: Window.Id, focused_frame: geometry.Rect, sel: Message.WindowSelector, current_space: Space.Id) ?Window.Id {
    const focused_cx = focused_frame.x + focused_frame.width / 2;
    const focused_cy = focused_frame.y + focused_frame.height / 2;

    // Get windows on current space only
    const windows = ctx.windows.getWindowsForSpace(current_space);

    var best_wid: ?Window.Id = null;
    var best_dist: f64 = std.math.floatMax(f64);

    for (windows) |wid| {
        if (wid == focused_wid) continue;

        const frame = Window.getFrame(wid) catch continue;
        const cx = frame.x + frame.width / 2;
        const cy = frame.y + frame.height / 2;

        const in_direction = switch (sel) {
            .west => cx < focused_cx,
            .east => cx > focused_cx,
            .north => cy < focused_cy,
            .south => cy > focused_cy,
            else => false,
        };

        if (!in_direction) continue;

        const dx = cx - focused_cx;
        const dy = cy - focused_cy;
        const dist = @sqrt(dx * dx + dy * dy);

        if (dist < best_dist) {
            best_dist = dist;
            best_wid = wid;
        }
    }

    return best_wid;
}

fn getVisibleWindowIds(ctx: *Context) ?[]u32 {
    const sl = ctx.skylight;
    const cid = ctx.connection;

    const current_space = getCurrentSpaceId(ctx) orelse return null;

    var space_id = current_space;
    const space_num = c.c.CFNumberCreate(null, c.c.kCFNumberSInt64Type, &space_id);
    if (space_num == null) return null;
    defer c.c.CFRelease(space_num);

    const space_array = c.c.CFArrayCreate(null, @ptrCast(@constCast(&space_num)), 1, &c.c.kCFTypeArrayCallBacks);
    if (space_array == null) return null;
    defer c.c.CFRelease(space_array);

    var set_tags: u64 = 0;
    var clear_tags: u64 = 0;
    const window_list = sl.SLSCopyWindowsWithOptionsAndTags(cid, 0, space_array, 0x2, &set_tags, &clear_tags);
    if (window_list == null) return null;
    defer c.c.CFRelease(window_list);

    const count: usize = @intCast(c.c.CFArrayGetCount(window_list));
    if (count == 0) return null;

    var windows = ctx.allocator.alloc(u32, count) catch return null;
    var valid_count: usize = 0;

    for (0..count) |i| {
        const val = c.c.CFArrayGetValueAtIndex(window_list, @intCast(i));
        const num: c.c.CFNumberRef = @ptrCast(@constCast(val));
        var wid: u32 = 0;
        if (c.c.CFNumberGetValue(num, c.c.kCFNumberSInt32Type, &wid) == 0) continue;
        if (wid == 0) continue;

        var level: c_int = 0;
        if (sl.SLSGetWindowLevel(cid, wid, &level) != 0) continue;
        if (level != 0) continue;

        windows[valid_count] = wid;
        valid_count += 1;
    }

    if (valid_count == 0) {
        ctx.allocator.free(windows);
        return null;
    }

    return ctx.allocator.realloc(windows, valid_count) catch windows[0..valid_count];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "configSet layout bsp" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "layout", "bsp");
    try testing.expectEqual(Result{ .ok = "" }, result);
    try testing.expectEqual(Spaces.LayoutType.bsp, sm.layout);
}

test "configSet layout stack" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "layout", "stack");
    try testing.expectEqual(Result{ .ok = "" }, result);
    try testing.expectEqual(Spaces.LayoutType.stack, sm.layout);
}

test "configSet layout float" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "layout", "float");
    try testing.expectEqual(Result{ .ok = "" }, result);
    try testing.expectEqual(Spaces.LayoutType.float, sm.layout);
}

test "configSet layout invalid returns error" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "layout", "invalid");
    try testing.expect(result == .err);
    try testing.expectEqual(Response.ErrorCode.invalid_value, result.err.code);
}

test "configSet window_gap" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "window_gap", "20");
    try testing.expectEqual(Result{ .ok = "" }, result);
    try testing.expectEqual(@as(i32, 20), sm.window_gap);
    try testing.expectEqual(@as(u32, 20), cfg.window_gap);
}

test "configSet gap alias" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "gap", "15");
    try testing.expectEqual(Result{ .ok = "" }, result);
    try testing.expectEqual(@as(i32, 15), sm.window_gap);
}

test "configSet window_gap negative returns error" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "window_gap", "-5");
    try testing.expect(result == .err);
    try testing.expectEqual(Response.ErrorCode.invalid_value, result.err.code);
}

test "configSet window_gap non-integer returns error" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "window_gap", "abc");
    try testing.expect(result == .err);
    try testing.expectEqual(Response.ErrorCode.invalid_value, result.err.code);
}

test "configSet padding values" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    _ = configSet(&ctx, "top_padding", "10");
    _ = configSet(&ctx, "bottom_padding", "20");
    _ = configSet(&ctx, "left_padding", "30");
    _ = configSet(&ctx, "right_padding", "40");

    try testing.expectEqual(@as(i32, 10), sm.padding.top);
    try testing.expectEqual(@as(i32, 20), sm.padding.bottom);
    try testing.expectEqual(@as(i32, 30), sm.padding.left);
    try testing.expectEqual(@as(i32, 40), sm.padding.right);
}

test "configSet split_ratio" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "split_ratio", "0.6");
    try testing.expectEqual(Result{ .ok = "" }, result);
    try testing.expectApproxEqAbs(@as(f32, 0.6), sm.split_ratio, 0.001);
}

test "configSet split_ratio out of range returns error" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "split_ratio", "0.05");
    try testing.expect(result == .err);

    const result2 = configSet(&ctx, "split_ratio", "0.95");
    try testing.expect(result2 == .err);
}

test "configSet auto_balance on/off" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    _ = configSet(&ctx, "auto_balance", "on");
    try testing.expect(sm.auto_balance);

    _ = configSet(&ctx, "auto_balance", "off");
    try testing.expect(!sm.auto_balance);

    _ = configSet(&ctx, "auto_balance", "true");
    try testing.expect(sm.auto_balance);

    _ = configSet(&ctx, "auto_balance", "false");
    try testing.expect(!sm.auto_balance);
}

test "configSet unknown key returns error" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = configSet(&ctx, "unknown_key", "value");
    try testing.expect(result == .err);
    try testing.expectEqual(Response.ErrorCode.unknown_command, result.err.code);
}

test "resolveSpace with label" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    sm.setLabel(12345, "code") catch unreachable;

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = resolveSpace(&ctx, .{ .label = "code" });
    try testing.expectEqual(@as(?u64, 12345), result);
}

test "resolveSpace with id" {
    var sm = Spaces.init(testing.allocator);
    defer sm.deinit();
    var wm = Windows.init(testing.allocator);
    defer wm.deinit();
    var dm = Displays.init(testing.allocator);
    defer dm.deinit();
    var cfg = Config{};

    var ctx = Context{
        .allocator = testing.allocator,
        .skylight = undefined,
        .connection = 0,
        .windows = &wm,
        .spaces = &sm,
        .displays = &dm,
        .config = &cfg,
        .applyLayout = struct {
            fn f(_: *Context, _: u64) void {}
        }.f,
        .getBoundsForSpace = struct {
            fn f(_: *Context, _: u64) ?geometry.Rect {
                return null;
            }
        }.f,
    };

    const result = resolveSpace(&ctx, .{ .id = 999 });
    try testing.expectEqual(@as(?u64, 999), result);
}

test "Result union ok case" {
    const result: Result = .{ .ok = "success" };
    try testing.expect(result == .ok);
    try testing.expectEqualStrings("success", result.ok);
}

test "Result union err case" {
    const result: Result = .{ .err = Response.err(.window_not_found) };
    try testing.expect(result == .err);
    try testing.expectEqual(Response.ErrorCode.window_not_found, result.err.code);
}
