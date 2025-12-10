const std = @import("std");
const c = @import("../platform/c.zig");

// ============================================================================
// Objective-C runtime helpers
// ============================================================================

const objc = struct {
    pub const Class = c.c.Class;
    pub const SEL = c.c.SEL;
    pub const id = c.c.id;

    pub fn getClass(name: [*:0]const u8) ?Class {
        return c.c.objc_getClass(name);
    }

    pub fn sel(name: [*:0]const u8) SEL {
        return c.c.sel_registerName(name);
    }

    /// Cast Class to id for message sending
    pub fn classAsId(cls: Class) id {
        return @ptrCast(@alignCast(cls));
    }
};

// Declare objc_msgSend with proper extern linkage
extern fn objc_msgSend() callconv(.c) void;

// Generic msgSend for zero-arg methods only
fn msgSend(comptime ReturnType: type) *const fn (objc.id, objc.SEL) callconv(.c) ReturnType {
    return @ptrCast(&objc_msgSend);
}

// Typed msgSend variants for methods with arguments (avoids variadic issues)
fn msgSendIdx(comptime ReturnType: type) *const fn (objc.id, objc.SEL, c_ulong) callconv(.c) ReturnType {
    return @ptrCast(&objc_msgSend);
}

fn msgSendPtr(comptime ReturnType: type) *const fn (objc.id, objc.SEL, ?*const anyopaque) callconv(.c) ReturnType {
    return @ptrCast(&objc_msgSend);
}

fn msgSendStr(comptime ReturnType: type) *const fn (objc.id, objc.SEL, [*:0]const u8) callconv(.c) ReturnType {
    return @ptrCast(&objc_msgSend);
}

fn msgSendId(comptime ReturnType: type) *const fn (objc.id, objc.SEL, objc.id) callconv(.c) ReturnType {
    return @ptrCast(&objc_msgSend);
}

fn msgSendPid(comptime ReturnType: type) *const fn (objc.id, objc.SEL, c.pid_t) callconv(.c) ReturnType {
    return @ptrCast(&objc_msgSend);
}

// ============================================================================
// OS Version detection
// ============================================================================

pub const OSVersion = struct {
    major: i64,
    minor: i64,
    patch: i64,
};

/// Get the current macOS version
/// NOTE: Requires NSApplicationLoad() to have been called first
pub fn getOSVersion() OSVersion {
    const NSProcessInfo = objc.getClass("NSProcessInfo") orelse return .{ .major = 0, .minor = 0, .patch = 0 };
    const processInfo = msgSend(objc.id)(objc.classAsId(NSProcessInfo), objc.sel("processInfo"));
    if (processInfo == null) return .{ .major = 0, .minor = 0, .patch = 0 };

    // NSOperatingSystemVersion is a struct { NSInteger major, minor, patch }
    const VersionGetter = *const fn (objc.id, objc.SEL) callconv(.c) extern struct { major: i64, minor: i64, patch: i64 };
    const getter: VersionGetter = @ptrCast(&objc_msgSend);
    const version = getter(processInfo, objc.sel("operatingSystemVersion"));

    return .{
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
    };
}

/// Check if running on a specific macOS version
pub fn isMacOS(major: i64) bool {
    return getOSVersion().major == major;
}

/// Check if space workaround is needed (certain macOS versions)
pub fn needsSpaceWorkaround() bool {
    const v = getOSVersion();
    if (v.major == 12 and v.minor >= 7) return true;
    if (v.major == 13 and v.minor >= 6) return true;
    if (v.major == 14 and v.minor >= 5) return true;
    return v.major >= 15;
}

// ============================================================================
// Dock utilities
// ============================================================================

/// Get the PID of the Dock process
/// NOTE: Requires NSApplicationLoad() to have been called first
pub fn getDockPid() c.pid_t {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return 0;
    const NSString = objc.getClass("NSString") orelse return 0;

    // Create @"com.apple.dock"
    const bundleId = msgSendStr(objc.id)(objc.classAsId(NSString), objc.sel("stringWithUTF8String:"), "com.apple.dock");
    if (bundleId == null) return 0;

    // Get running applications with bundle identifier
    const list = msgSendId(objc.id)(objc.classAsId(NSRunningApplication), objc.sel("runningApplicationsWithBundleIdentifier:"), bundleId);
    if (list == null) return 0;

    // Check count
    const count = msgSend(c_ulong)(list, objc.sel("count"));
    if (count != 1) return 0;

    // Get first object
    const dock = msgSendIdx(objc.id)(list, objc.sel("objectAtIndex:"), 0);
    if (dock == null) return 0;

    // Get process identifier
    return msgSend(c.pid_t)(dock, objc.sel("processIdentifier"));
}

// ============================================================================
// Display utilities
// ============================================================================

/// Get the notch height for a display (0 if not built-in or no notch)
/// NOTE: Requires NSApplicationLoad() to have been called first
pub fn getDisplayNotchHeight(display_id: u32) c_int {
    // CGDisplayIsBuiltin check
    if (c.c.CGDisplayIsBuiltin(display_id) == 0) return 0;

    const NSScreen = objc.getClass("NSScreen") orelse return 0;
    const screens = msgSend(objc.id)(objc.classAsId(NSScreen), objc.sel("screens"));
    if (screens == null) return 0;

    const count = msgSend(c_ulong)(screens, objc.sel("count"));

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const screen = msgSendIdx(objc.id)(screens, objc.sel("objectAtIndex:"), i);
        if (screen == null) continue;

        const deviceDescription = msgSend(objc.id)(screen, objc.sel("deviceDescription"));
        if (deviceDescription == null) continue;

        const NSString = objc.getClass("NSString") orelse continue;
        const key = msgSendStr(objc.id)(objc.classAsId(NSString), objc.sel("stringWithUTF8String:"), "NSScreenNumber");
        if (key == null) continue;

        const screenNumber = msgSendId(objc.id)(deviceDescription, objc.sel("objectForKey:"), key);
        if (screenNumber == null) continue;

        const did = msgSend(c_uint)(screenNumber, objc.sel("unsignedIntValue"));
        if (did == display_id) {
            // Get safeAreaInsets.top using NSEdgeInsets struct
            // safeAreaInsets returns NSEdgeInsets { top, left, bottom, right } as doubles
            const SafeAreaGetter = *const fn (objc.id, objc.SEL) callconv(.c) extern struct {
                top: f64,
                left: f64,
                bottom: f64,
                right: f64,
            };
            const getter: SafeAreaGetter = @ptrCast(&objc_msgSend);
            const insets = getter(screen, objc.sel("safeAreaInsets"));
            return @intFromFloat(insets.top);
        }
    }

    return 0;
}

// ============================================================================
// NSRunningApplication utilities
// ============================================================================

/// Application activation policy
pub const ActivationPolicy = enum(i64) {
    regular = 0,
    accessory = 1,
    prohibited = 2,
};

/// Get a running application by PID. Returns null if not found.
/// Caller must call releaseApplication() when done.
/// NOTE: Requires NSApplicationLoad() to have been called first
pub fn getRunningApplication(pid: c.pid_t) ?objc.id {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return null;
    const app = msgSendPid(objc.id)(objc.classAsId(NSRunningApplication), objc.sel("runningApplicationWithProcessIdentifier:"), pid);
    if (app == null) return null;
    // Retain for the caller
    return msgSend(objc.id)(app, objc.sel("retain"));
}

/// Get the activation policy of an application
pub fn getActivationPolicy(app: objc.id) ActivationPolicy {
    const policy = msgSend(i64)(app, objc.sel("activationPolicy"));
    return @enumFromInt(policy);
}

/// Check if an application has finished launching
pub fn isFinishedLaunching(app: objc.id) bool {
    return msgSend(c.c.BOOL)(app, objc.sel("isFinishedLaunching")) != 0;
}

/// Release an NSRunningApplication
pub fn releaseApplication(app: objc.id) void {
    _ = msgSend(void)(app, objc.sel("release"));
}

/// Running application info from NSWorkspace
pub const RunningApp = struct {
    pid: c.pid_t,
    policy: ActivationPolicy,
};

/// Iterate over all running applications from NSWorkspace
/// Calls the callback for each regular (foreground) application
pub fn iterateRunningApps(skip_pid: c.pid_t, callback: *const fn (c.pid_t) void) void {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return;
    const shared = msgSend(objc.id)(objc.classAsId(NSWorkspace), objc.sel("sharedWorkspace"));
    if (shared == null) return;

    const apps = msgSend(objc.id)(shared, objc.sel("runningApplications"));
    if (apps == null) return;

    const count = msgSend(c_ulong)(apps, objc.sel("count"));

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const app = msgSendIdx(objc.id)(apps, objc.sel("objectAtIndex:"), i);
        if (app == null) continue;

        const pid = msgSend(c.pid_t)(app, objc.sel("processIdentifier"));
        if (pid <= 0 or pid == skip_pid) continue;

        const policy = msgSend(i64)(app, objc.sel("activationPolicy"));
        if (policy != 0) continue; // Only regular apps

        callback(pid);
    }
}

/// Get all regular (foreground) running application PIDs
/// Get all regular (foreground) running application PIDs
pub fn getRunningAppPids(allocator: std.mem.Allocator, skip_pid: c.pid_t) ![]c.pid_t {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return &[_]c.pid_t{};
    const shared = msgSend(objc.id)(objc.classAsId(NSWorkspace), objc.sel("sharedWorkspace"));
    if (shared == null) return &[_]c.pid_t{};

    const apps = msgSend(objc.id)(shared, objc.sel("runningApplications"));
    if (apps == null) return &[_]c.pid_t{};

    const count = msgSend(c_ulong)(apps, objc.sel("count"));
    if (count == 0) return &[_]c.pid_t{};

    const sel_objectAtIndex = objc.sel("objectAtIndex:");

    // First pass: count valid apps
    var valid_count: usize = 0;
    {
        var i: c_ulong = 0;
        while (i < count) : (i += 1) {
            const app = msgSendIdx(objc.id)(apps, sel_objectAtIndex, i);
            if (app == null) continue;

            const pid = msgSend(c.pid_t)(app, objc.sel("processIdentifier"));
            if (pid <= 0 or pid == skip_pid) continue;

            const policy = msgSend(i64)(app, objc.sel("activationPolicy"));
            if (policy != 0) continue;

            valid_count += 1;
        }
    }

    if (valid_count == 0) return &[_]c.pid_t{};

    // Allocate exact size
    const pids = try allocator.alloc(c.pid_t, valid_count);
    errdefer allocator.free(pids);

    // Second pass: collect PIDs
    var idx: usize = 0;
    {
        var i: c_ulong = 0;
        while (i < count) : (i += 1) {
            const app = msgSendIdx(objc.id)(apps, sel_objectAtIndex, i);
            if (app == null) continue;

            const pid = msgSend(c.pid_t)(app, objc.sel("processIdentifier"));
            if (pid <= 0 or pid == skip_pid) continue;

            const policy = msgSend(i64)(app, objc.sel("activationPolicy"));
            if (policy != 0) continue;

            pids[idx] = pid;
            idx += 1;
        }
    }

    return pids;
}

// ============================================================================
// Notification constants
// ============================================================================

pub const Notification = struct {
    // NSWorkspace notifications
    pub const active_space_changed = "NSWorkspaceActiveSpaceDidChangeNotification";
    pub const active_display_changed = "NSWorkspaceActiveDisplayDidChangeNotification";
    pub const did_hide_application = "NSWorkspaceDidHideApplicationNotification";
    pub const did_unhide_application = "NSWorkspaceDidUnhideApplicationNotification";
    pub const did_wake = "NSWorkspaceDidWakeNotification";

    // NSDistributedNotificationCenter
    pub const menu_bar_hiding_changed = "AppleInterfaceMenuBarHidingChangedNotification";
    pub const dock_pref_changed = "com.apple.dock.prefchanged";

    // NSNotificationCenter
    pub const dock_did_restart = "NSApplicationDockDidRestartNotification";
};

// ============================================================================
// Tests
// ============================================================================

test "ActivationPolicy enum values" {
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(ActivationPolicy.regular));
    try std.testing.expectEqual(@as(i64, 1), @intFromEnum(ActivationPolicy.accessory));
    try std.testing.expectEqual(@as(i64, 2), @intFromEnum(ActivationPolicy.prohibited));
}

test "objc.sel returns non-null" {
    const sel = objc.sel("init");
    try std.testing.expect(sel != null);
}

test "objc.getClass for known class" {
    // NSObject should always exist
    const cls = objc.getClass("NSObject");
    try std.testing.expect(cls != null);
}

// ============================================================================
// Integration tests - require ObjC runtime
// ============================================================================

test "getOSVersion returns valid macOS version" {
    const v = getOSVersion();
    // macOS versions: 10.x, 11.x (Big Sur), 12.x (Monterey), 13.x (Ventura), 14.x (Sonoma), 15.x (Sequoia), 26.x (preview)
    try std.testing.expect(v.major >= 10);
    try std.testing.expect(v.major <= 50); // reasonable upper bound for future versions
    try std.testing.expect(v.minor >= 0);
    try std.testing.expect(v.patch >= 0);
}

test "getDockPid returns positive pid" {
    const pid = getDockPid();
    // Dock should always be running on macOS
    try std.testing.expect(pid > 0);
}

test "getRunningAppPids returns valid pids" {
    const allocator = std.testing.allocator;
    const pids = try getRunningAppPids(allocator, 0);
    defer allocator.free(pids);

    // There should be at least one regular app running (Finder at minimum)
    try std.testing.expect(pids.len > 0);

    // All PIDs should be positive
    for (pids) |pid| {
        try std.testing.expect(pid > 0);
    }
}

test "getRunningAppPids skip_pid filtering works" {
    const allocator = std.testing.allocator;

    // Get all pids first
    const all_pids = try getRunningAppPids(allocator, 0);
    defer allocator.free(all_pids);

    if (all_pids.len == 0) return; // skip if no apps

    // Skip the first pid and verify it's not in results
    const skip = all_pids[0];
    const filtered_pids = try getRunningAppPids(allocator, skip);
    defer allocator.free(filtered_pids);

    for (filtered_pids) |pid| {
        try std.testing.expect(pid != skip);
    }
}

test "getRunningApplication returns valid app for Dock" {
    const dock_pid = getDockPid();
    try std.testing.expect(dock_pid > 0);

    const app = getRunningApplication(dock_pid);
    try std.testing.expect(app != null);
    defer releaseApplication(app.?);

    // Dock has accessory activation policy (it's a background app with UI)
    const policy = getActivationPolicy(app.?);
    try std.testing.expectEqual(ActivationPolicy.accessory, policy);
}

test "getDisplayNotchHeight doesn't crash" {
    // Just verify it doesn't crash with invalid display id
    const height = getDisplayNotchHeight(0);
    try std.testing.expect(height >= 0);
}

test "iterateRunningApps calls callback with valid pids" {
    const S = struct {
        var count: usize = 0;
        var all_positive: bool = true;

        fn callback(pid: c.pid_t) void {
            count += 1;
            if (pid <= 0) all_positive = false;
        }
    };

    S.count = 0;
    S.all_positive = true;

    iterateRunningApps(0, S.callback);

    // Should find at least one app
    try std.testing.expect(S.count > 0);
    try std.testing.expect(S.all_positive);
}
