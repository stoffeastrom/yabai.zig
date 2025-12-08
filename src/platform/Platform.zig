const std = @import("std");
const geometry = @import("../core/geometry.zig");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Display = @import("../core/Display.zig");
const Record = @import("../events/Record.zig").Record;

/// Platform abstraction for OS operations.
/// Real: actual macOS calls (SkyLight, AX, SA)
/// Mock: replays recorded data for testing
pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // === Window Queries ===
        getWindowFrame: *const fn (ptr: *anyopaque, window_id: Window.Id) ?geometry.Rect,
        getWindowSpace: *const fn (ptr: *anyopaque, window_id: Window.Id) ?Space.Id,
        getWindowOwner: *const fn (ptr: *anyopaque, window_id: Window.Id) ?i32,
        getWindowLevel: *const fn (ptr: *anyopaque, window_id: Window.Id) ?i32,
        isWindowMinimized: *const fn (ptr: *anyopaque, window_id: Window.Id) bool,
        isWindowFullscreen: *const fn (ptr: *anyopaque, window_id: Window.Id) bool,

        // === Window Commands ===
        setWindowFrame: *const fn (ptr: *anyopaque, window_id: Window.Id, frame: geometry.Rect) bool,
        setWindowLevel: *const fn (ptr: *anyopaque, window_id: Window.Id, level: i32) bool,
        setWindowOpacity: *const fn (ptr: *anyopaque, window_id: Window.Id, opacity: f32) bool,
        focusWindow: *const fn (ptr: *anyopaque, window_id: Window.Id) bool,
        minimizeWindow: *const fn (ptr: *anyopaque, window_id: Window.Id) bool,
        closeWindow: *const fn (ptr: *anyopaque, window_id: Window.Id) bool,

        // === Space Queries ===
        getSpaceType: *const fn (ptr: *anyopaque, space_id: Space.Id) Record.SpaceType,
        getSpaceDisplay: *const fn (ptr: *anyopaque, space_id: Space.Id) ?Display.Id,
        getSpaceWindows: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, space_id: Space.Id) ?[]Window.Id,
        getActiveSpaceForDisplay: *const fn (ptr: *anyopaque, display_id: Display.Id) ?Space.Id,

        // === Space Commands (via SA) ===
        focusSpace: *const fn (ptr: *anyopaque, space_id: Space.Id) bool,
        moveWindowToSpace: *const fn (ptr: *anyopaque, window_id: Window.Id, space_id: Space.Id) bool,
        createSpace: *const fn (ptr: *anyopaque, display_id: Display.Id) ?Space.Id,
        destroySpace: *const fn (ptr: *anyopaque, space_id: Space.Id) bool,

        // === Display Queries ===
        getDisplayFrame: *const fn (ptr: *anyopaque, display_id: Display.Id) ?geometry.Rect,
        getDisplaySpaces: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, display_id: Display.Id) ?[]Space.Id,
        getAllDisplays: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) ?[]Display.Id,

        // === App Queries ===
        getAppName: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, pid: i32) ?[]const u8,
        getAppBundleId: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, pid: i32) ?[]const u8,
        isAppHidden: *const fn (ptr: *anyopaque, pid: i32) bool,

        // === System ===
        getCursorPosition: *const fn (ptr: *anyopaque) geometry.Point,
        getFocusedWindowId: *const fn (ptr: *anyopaque) ?Window.Id,
        getFocusedPid: *const fn (ptr: *anyopaque) ?i32,
    };

    // === Window Queries ===

    pub fn getWindowFrame(self: Platform, window_id: Window.Id) ?geometry.Rect {
        return self.vtable.getWindowFrame(self.ptr, window_id);
    }

    pub fn getWindowSpace(self: Platform, window_id: Window.Id) ?Space.Id {
        return self.vtable.getWindowSpace(self.ptr, window_id);
    }

    pub fn getWindowOwner(self: Platform, window_id: Window.Id) ?i32 {
        return self.vtable.getWindowOwner(self.ptr, window_id);
    }

    pub fn getWindowLevel(self: Platform, window_id: Window.Id) ?i32 {
        return self.vtable.getWindowLevel(self.ptr, window_id);
    }

    pub fn isWindowMinimized(self: Platform, window_id: Window.Id) bool {
        return self.vtable.isWindowMinimized(self.ptr, window_id);
    }

    pub fn isWindowFullscreen(self: Platform, window_id: Window.Id) bool {
        return self.vtable.isWindowFullscreen(self.ptr, window_id);
    }

    // === Window Commands ===

    pub fn setWindowFrame(self: Platform, window_id: Window.Id, frame: geometry.Rect) bool {
        return self.vtable.setWindowFrame(self.ptr, window_id, frame);
    }

    pub fn setWindowLevel(self: Platform, window_id: Window.Id, level: i32) bool {
        return self.vtable.setWindowLevel(self.ptr, window_id, level);
    }

    pub fn setWindowOpacity(self: Platform, window_id: Window.Id, opacity: f32) bool {
        return self.vtable.setWindowOpacity(self.ptr, window_id, opacity);
    }

    pub fn focusWindow(self: Platform, window_id: Window.Id) bool {
        return self.vtable.focusWindow(self.ptr, window_id);
    }

    pub fn minimizeWindow(self: Platform, window_id: Window.Id) bool {
        return self.vtable.minimizeWindow(self.ptr, window_id);
    }

    pub fn closeWindow(self: Platform, window_id: Window.Id) bool {
        return self.vtable.closeWindow(self.ptr, window_id);
    }

    // === Space Queries ===

    pub fn getSpaceType(self: Platform, space_id: Space.Id) Record.SpaceType {
        return self.vtable.getSpaceType(self.ptr, space_id);
    }

    pub fn getSpaceDisplay(self: Platform, space_id: Space.Id) ?Display.Id {
        return self.vtable.getSpaceDisplay(self.ptr, space_id);
    }

    pub fn getSpaceWindows(self: Platform, allocator: std.mem.Allocator, space_id: Space.Id) ?[]Window.Id {
        return self.vtable.getSpaceWindows(self.ptr, allocator, space_id);
    }

    pub fn getActiveSpaceForDisplay(self: Platform, display_id: Display.Id) ?Space.Id {
        return self.vtable.getActiveSpaceForDisplay(self.ptr, display_id);
    }

    // === Space Commands ===

    pub fn focusSpace(self: Platform, space_id: Space.Id) bool {
        return self.vtable.focusSpace(self.ptr, space_id);
    }

    pub fn moveWindowToSpace(self: Platform, window_id: Window.Id, space_id: Space.Id) bool {
        return self.vtable.moveWindowToSpace(self.ptr, window_id, space_id);
    }

    pub fn createSpace(self: Platform, display_id: Display.Id) ?Space.Id {
        return self.vtable.createSpace(self.ptr, display_id);
    }

    pub fn destroySpace(self: Platform, space_id: Space.Id) bool {
        return self.vtable.destroySpace(self.ptr, space_id);
    }

    // === Display Queries ===

    pub fn getDisplayFrame(self: Platform, display_id: Display.Id) ?geometry.Rect {
        return self.vtable.getDisplayFrame(self.ptr, display_id);
    }

    pub fn getDisplaySpaces(self: Platform, allocator: std.mem.Allocator, display_id: Display.Id) ?[]Space.Id {
        return self.vtable.getDisplaySpaces(self.ptr, allocator, display_id);
    }

    pub fn getAllDisplays(self: Platform, allocator: std.mem.Allocator) ?[]Display.Id {
        return self.vtable.getAllDisplays(self.ptr, allocator);
    }

    // === App Queries ===

    pub fn getAppName(self: Platform, allocator: std.mem.Allocator, pid: i32) ?[]const u8 {
        return self.vtable.getAppName(self.ptr, allocator, pid);
    }

    pub fn getAppBundleId(self: Platform, allocator: std.mem.Allocator, pid: i32) ?[]const u8 {
        return self.vtable.getAppBundleId(self.ptr, allocator, pid);
    }

    pub fn isAppHidden(self: Platform, pid: i32) bool {
        return self.vtable.isAppHidden(self.ptr, pid);
    }

    // === System ===

    pub fn getCursorPosition(self: Platform) geometry.Point {
        return self.vtable.getCursorPosition(self.ptr);
    }

    pub fn getFocusedWindowId(self: Platform) ?Window.Id {
        return self.vtable.getFocusedWindowId(self.ptr);
    }

    pub fn getFocusedPid(self: Platform) ?i32 {
        return self.vtable.getFocusedPid(self.ptr);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Platform interface compiles" {
    // Just verify the interface compiles correctly
    const vtable = Platform.VTable{
        .getWindowFrame = undefined,
        .getWindowSpace = undefined,
        .getWindowOwner = undefined,
        .getWindowLevel = undefined,
        .isWindowMinimized = undefined,
        .isWindowFullscreen = undefined,
        .setWindowFrame = undefined,
        .setWindowLevel = undefined,
        .setWindowOpacity = undefined,
        .focusWindow = undefined,
        .minimizeWindow = undefined,
        .closeWindow = undefined,
        .getSpaceType = undefined,
        .getSpaceDisplay = undefined,
        .getSpaceWindows = undefined,
        .getActiveSpaceForDisplay = undefined,
        .focusSpace = undefined,
        .moveWindowToSpace = undefined,
        .createSpace = undefined,
        .destroySpace = undefined,
        .getDisplayFrame = undefined,
        .getDisplaySpaces = undefined,
        .getAllDisplays = undefined,
        .getAppName = undefined,
        .getAppBundleId = undefined,
        .isAppHidden = undefined,
        .getCursorPosition = undefined,
        .getFocusedWindowId = undefined,
        .getFocusedPid = undefined,
    };
    _ = vtable;
}
