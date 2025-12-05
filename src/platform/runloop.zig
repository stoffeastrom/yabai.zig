const std = @import("std");
const c = @import("../platform/c.zig");

// ============================================================================
// CFRunLoop thin wrappers
// ============================================================================

/// Get the main run loop
pub fn getMain() c.c.CFRunLoopRef {
    return c.c.CFRunLoopGetMain();
}

/// Get the current thread's run loop
pub fn getCurrent() c.c.CFRunLoopRef {
    return c.c.CFRunLoopGetCurrent();
}

/// Run the current run loop
pub fn run() void {
    c.c.CFRunLoopRun();
}

/// Run the run loop once, processing one source or timeout
pub fn runOnce(seconds: f64) RunResult {
    const result = c.c.CFRunLoopRunInMode(c.c.kCFRunLoopDefaultMode, seconds, 1);
    return @enumFromInt(result);
}

/// Run the run loop in a specific mode
pub fn runInMode(mode: c.CFStringRef, seconds: f64, return_after_source: bool) RunResult {
    const result = c.c.CFRunLoopRunInMode(mode, seconds, @intFromBool(return_after_source));
    return @enumFromInt(result);
}

/// Stop the run loop
pub fn stop(rl: c.c.CFRunLoopRef) void {
    c.c.CFRunLoopStop(rl);
}

/// Wake up a run loop
pub fn wakeUp(rl: c.c.CFRunLoopRef) void {
    c.c.CFRunLoopWakeUp(rl);
}

/// Check if the run loop is waiting
pub fn isWaiting(rl: c.c.CFRunLoopRef) bool {
    return c.c.CFRunLoopIsWaiting(rl) != 0;
}

// ============================================================================
// Source management
// ============================================================================

/// Add a source to a run loop
pub fn addSource(rl: c.c.CFRunLoopRef, source: c.c.CFRunLoopSourceRef, mode: c.CFStringRef) void {
    c.c.CFRunLoopAddSource(rl, source, mode);
}

/// Remove a source from a run loop
pub fn removeSource(rl: c.c.CFRunLoopRef, source: c.c.CFRunLoopSourceRef, mode: c.CFStringRef) void {
    c.c.CFRunLoopRemoveSource(rl, source, mode);
}

/// Check if a source is in a run loop mode
pub fn containsSource(rl: c.c.CFRunLoopRef, source: c.c.CFRunLoopSourceRef, mode: c.CFStringRef) bool {
    return c.c.CFRunLoopContainsSource(rl, source, mode) != 0;
}

/// Invalidate a run loop source
pub fn invalidateSource(source: c.c.CFRunLoopSourceRef) void {
    c.c.CFRunLoopSourceInvalidate(source);
}

/// Signal a run loop source
pub fn signalSource(source: c.c.CFRunLoopSourceRef) void {
    c.c.CFRunLoopSourceSignal(source);
}

// ============================================================================
// Timer management
// ============================================================================

/// Add a timer to a run loop
pub fn addTimer(rl: c.c.CFRunLoopRef, timer: c.c.CFRunLoopTimerRef, mode: c.CFStringRef) void {
    c.c.CFRunLoopAddTimer(rl, timer, mode);
}

/// Remove a timer from a run loop
pub fn removeTimer(rl: c.c.CFRunLoopRef, timer: c.c.CFRunLoopTimerRef, mode: c.CFStringRef) void {
    c.c.CFRunLoopRemoveTimer(rl, timer, mode);
}

// ============================================================================
// Observer management
// ============================================================================

/// Add an observer to a run loop
pub fn addObserver(rl: c.c.CFRunLoopRef, observer: c.c.CFRunLoopObserverRef, mode: c.CFStringRef) void {
    c.c.CFRunLoopAddObserver(rl, observer, mode);
}

/// Remove an observer from a run loop
pub fn removeObserver(rl: c.c.CFRunLoopRef, observer: c.c.CFRunLoopObserverRef, mode: c.CFStringRef) void {
    c.c.CFRunLoopRemoveObserver(rl, observer, mode);
}

// ============================================================================
// Run loop modes - accessed via functions since C globals aren't comptime
// ============================================================================

pub fn defaultMode() c.CFStringRef {
    return c.c.kCFRunLoopDefaultMode;
}

pub fn commonModes() c.CFStringRef {
    return c.c.kCFRunLoopCommonModes;
}

// ============================================================================
// Run result
// ============================================================================

pub const RunResult = enum(i32) {
    finished = 1,
    stopped = 2,
    timed_out = 3,
    handled_source = 4,
};

// ============================================================================
// Convenience: Add AXObserver source to main run loop
// ============================================================================

/// Add an AXObserver's run loop source to the main run loop
pub fn addAXObserver(observer: c.c.AXObserverRef) void {
    const source = c.c.AXObserverGetRunLoopSource(observer);
    addSource(getMain(), source, defaultMode());
}

/// Remove and invalidate an AXObserver's run loop source
pub fn removeAXObserver(observer: c.c.AXObserverRef) void {
    const source = c.c.AXObserverGetRunLoopSource(observer);
    removeSource(getMain(), source, defaultMode());
    invalidateSource(source);
}

// ============================================================================
// Tests
// ============================================================================

test "getMain returns non-null" {
    const rl = getMain();
    try std.testing.expect(rl != null);
}

test "getCurrent returns non-null" {
    const rl = getCurrent();
    try std.testing.expect(rl != null);
}

test "mode functions return valid values" {
    try std.testing.expect(defaultMode() != null);
    try std.testing.expect(commonModes() != null);
}
