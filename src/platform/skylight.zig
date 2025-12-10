const std = @import("std");
const c = @import("c.zig");
const macho = @import("../sa/macho.zig");

const SKYLIGHT_PATH = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
const COREGRAPHICS_PATH = "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics";

pub const ConnectionCallback = *const fn (
    event_type: u32,
    data: ?*anyopaque,
    data_length: usize,
    context: ?*anyopaque,
    cid: c_int,
) callconv(.c) void;

fn lookup(comptime T: type, comptime symbol: [:0]const u8) ?T {
    return macho.findSymbol(T, SKYLIGHT_PATH, symbol);
}

fn lookupCG(comptime T: type, comptime symbol: [:0]const u8) ?T {
    // Try SkyLight first, then CoreGraphics
    return macho.findSymbol(T, SKYLIGHT_PATH, symbol) orelse
        macho.findSymbol(T, COREGRAPHICS_PATH, symbol);
}

pub const SkyLight = struct {
    // Connection management
    SLSMainConnectionID: *const fn () callconv(.c) c_int,
    SLSNewConnection: *const fn (c_int, *c_int) callconv(.c) c.CGError,
    SLSReleaseConnection: *const fn (c_int) callconv(.c) c.CGError,
    SLSRegisterConnectionNotifyProc: *const fn (c_int, ConnectionCallback, u32, ?*anyopaque) callconv(.c) c.CGError,
    SLSGetConnectionPSN: *const fn (c_int, *c.c.ProcessSerialNumber) callconv(.c) c.CGError,
    SLSConnectionGetPID: *const fn (c_int, *c.pid_t) callconv(.c) c.CGError,
    SLSGetConnectionIDForPSN: *const fn (c_int, *c.c.ProcessSerialNumber, *c_int) callconv(.c) c.CGError,

    // Window geometry & properties
    SLSGetWindowBounds: *const fn (c_int, u32, *c.CGRect) callconv(.c) c.CGError,
    SLSGetWindowLevel: *const fn (c_int, u32, *c_int) callconv(.c) c.CGError,
    SLSGetWindowSubLevel: *const fn (c_int, u32) callconv(.c) c_int,
    SLSGetWindowAlpha: *const fn (c_int, u32, *f32) callconv(.c) c.CGError,
    SLSSetWindowAlpha: *const fn (c_int, u32, f32) callconv(.c) c.CGError,
    SLSSetWindowLevel: *const fn (c_int, u32, c_int) callconv(.c) c.CGError,
    SLSSetWindowSubLevel: *const fn (c_int, u32, c_int) callconv(.c) c.CGError,
    SLSSetWindowOpacity: *const fn (c_int, u32, bool) callconv(.c) c.CGError,
    SLSSetWindowResolution: *const fn (c_int, u32, f64) callconv(.c) c.CGError,
    SLSSetWindowTransform: *const fn (c_int, u32, c.c.CGAffineTransform) callconv(.c) c.CGError,
    SLSSetWindowBackgroundBlurRadiusStyle: *const fn (c_int, u32, c_int, c_int) callconv(.c) c.CGError,
    SLSWindowSetShadowProperties: *const fn (u32, c.CFDictionaryRef) callconv(.c) c.CGError,
    SLSCopyWindowProperty: *const fn (c_int, u32, c.CFStringRef, *c.CFTypeRef) callconv(.c) c.CGError,
    SLSWindowIsOrderedIn: *const fn (c_int, u32, *u8) callconv(.c) c.CGError,

    // Window ordering & movement
    SLSOrderWindow: *const fn (c_int, u32, c_int, u32) callconv(.c) c.CGError,
    SLSMoveWindow: *const fn (c_int, u32, *c.CGPoint) callconv(.c) c.CGError,
    SLSMoveWindowWithGroup: *const fn (c_int, u32, *c.CGPoint) callconv(.c) c.CGError,

    // Window tags
    SLSSetWindowTags: *const fn (c_int, u32, *u64, c_int) callconv(.c) c.CGError,
    SLSClearWindowTags: *const fn (c_int, u32, *u64, c_int) callconv(.c) c.CGError,

    // Window creation/destruction
    SLSNewWindow: *const fn (c_int, c_int, f32, f32, c.CFTypeRef, *u32) callconv(.c) c.CGError,
    SLSNewWindowWithOpaqueShapeAndContext: *const fn (c_int, c_int, c.CFTypeRef, c.CFTypeRef, c_int, *u64, f32, f32, c_int, *u32, ?*anyopaque) callconv(.c) c.CGError,
    SLSReleaseWindow: *const fn (c_int, u32) callconv(.c) c.CGError,
    SLSSetWindowShape: *const fn (c_int, u32, f32, f32, c.CFTypeRef) callconv(.c) c.CGError,
    CGSNewRegionWithRect: *const fn (*const c.CGRect, *c.CFTypeRef) callconv(.c) c.CGError,

    // Window ownership
    SLSGetWindowOwner: *const fn (c_int, u32, *c_int) callconv(.c) c.CGError,
    SLSCopyAssociatedWindows: *const fn (c_int, u32) callconv(.c) c.CFArrayRef,

    // Window queries (iterator pattern)
    SLSWindowQueryWindows: *const fn (c_int, c.CFArrayRef, c_int) callconv(.c) c.CFTypeRef,
    SLSWindowQueryResultCopyWindows: *const fn (c.CFTypeRef) callconv(.c) c.CFTypeRef,
    SLSWindowIteratorGetCount: *const fn (c.CFTypeRef) callconv(.c) c_int,
    SLSWindowIteratorAdvance: *const fn (c.CFTypeRef) callconv(.c) bool,
    SLSWindowIteratorGetWindowID: *const fn (c.CFTypeRef) callconv(.c) u32,
    SLSWindowIteratorGetParentID: *const fn (c.CFTypeRef) callconv(.c) u32,
    SLSWindowIteratorGetLevel: *const fn (c.CFTypeRef) callconv(.c) c_int,
    SLSWindowIteratorGetTags: *const fn (c.CFTypeRef) callconv(.c) u64,
    SLSWindowIteratorGetAttributes: *const fn (c.CFTypeRef) callconv(.c) u64,
    SLSCopyWindowsWithOptionsAndTags: *const fn (c_int, u32, c.CFArrayRef, u32, *u64, *u64) callconv(.c) c.CFArrayRef,

    // Window notifications
    SLSRequestNotificationsForWindows: *const fn (c_int, [*]u32, c_int) callconv(.c) c.CGError,

    // Display management
    SLSCopyManagedDisplays: *const fn (c_int) callconv(.c) c.CFArrayRef,
    SLSCopyManagedDisplayForWindow: *const fn (c_int, u32) callconv(.c) c.CFStringRef,
    SLSCopyBestManagedDisplayForRect: *const fn (c_int, c.CGRect) callconv(.c) c.CFStringRef,
    SLSCopyBestManagedDisplayForPoint: *const fn (c_int, c.CGPoint) callconv(.c) c.CFStringRef,
    SLSCopyActiveMenuBarDisplayIdentifier: *const fn (c_int) callconv(.c) c.CFStringRef,
    SLSSetActiveMenuBarDisplayIdentifier: *const fn (c_int, c.CFStringRef, c.CFStringRef) callconv(.c) c.CGError,
    SLSManagedDisplayIsAnimating: *const fn (c_int, c.CFStringRef) callconv(.c) bool,
    SLSGetDisplayMenubarHeight: *const fn (u32, *u32) callconv(.c) c.CGError,
    SLSGetDockRectWithReason: *const fn (c_int, *c.CGRect, *c_int) callconv(.c) c.CGError,
    SLSGetMenuBarAutohideEnabled: *const fn (c_int, *c_int) callconv(.c) c.CGError,
    SLSGetRevealedMenuBarBounds: *const fn (*c.CGRect, c_int, u64) callconv(.c) c.CGError,
    SLSSetMenuBarInsetAndAlpha: *const fn (c_int, f64, f64, f32) callconv(.c) c.CGError,

    // Space management
    SLSManagedDisplayGetCurrentSpace: *const fn (c_int, c.CFStringRef) callconv(.c) u64,
    SLSManagedDisplaySetCurrentSpace: *const fn (c_int, c.CFStringRef, u64) callconv(.c) c.CGError,
    SLSCopyManagedDisplaySpaces: *const fn (c_int) callconv(.c) c.CFArrayRef,
    SLSCopyManagedDisplayForSpace: *const fn (c_int, u64) callconv(.c) c.CFStringRef,
    SLSCopySpacesForWindows: *const fn (c_int, c_int, c.CFArrayRef) callconv(.c) c.CFArrayRef,
    SLSSpaceGetType: *const fn (c_int, u64) callconv(.c) c_int,
    SLSSpaceCopyName: *const fn (c_int, u64) callconv(.c) c.CFStringRef,
    SLSSpaceSetCompatID: *const fn (c_int, u64, c_int) callconv(.c) c.CGError,
    SLSGetSpaceManagementMode: *const fn (c_int) callconv(.c) c_int,
    SLSShowSpaces: *const fn (c_int, c.CFArrayRef) callconv(.c) c.CGError,
    SLSHideSpaces: *const fn (c_int, c.CFArrayRef) callconv(.c) c.CGError,
    SLSMoveWindowsToManagedSpace: *const fn (c_int, c.CFArrayRef, u64) callconv(.c) void,
    SLSSetWindowListWorkspace: *const fn (c_int, [*]u32, c_int, c_int) callconv(.c) c.CGError,

    // Process/space assignment
    SLSProcessAssignToSpace: *const fn (c_int, c.pid_t, u64) callconv(.c) c.CGError,
    SLSProcessAssignToAllSpaces: *const fn (c_int, c.pid_t) callconv(.c) c.CGError,
    SLSReassociateWindowsSpacesByGeometry: *const fn (c_int, c.CFArrayRef) callconv(.c) void,

    // Cursor
    SLSGetCurrentCursorLocation: *const fn (c_int, *c.CGPoint) callconv(.c) c.CGError,

    // Update control
    SLSDisableUpdate: *const fn (c_int) callconv(.c) c.CGError,
    SLSReenableUpdate: *const fn (c_int) callconv(.c) c.CGError,

    // Transactions (batched window operations)
    SLSTransactionCreate: *const fn (c_int) callconv(.c) c.CFTypeRef,
    SLSTransactionCommit: *const fn (c.CFTypeRef, c_int) callconv(.c) c.CGError,
    SLSTransactionSetWindowTransform: *const fn (c.CFTypeRef, u32, c_int, c_int, c.c.CGAffineTransform) callconv(.c) c.CGError,
    SLSTransactionOrderWindow: *const fn (c.CFTypeRef, u32, c_int, u32) callconv(.c) c.CGError,
    SLSTransactionOrderWindowGroup: *const fn (c.CFTypeRef, u32, c_int, u32) callconv(.c) c.CGError,
    SLSTransactionSetWindowAlpha: *const fn (c.CFTypeRef, u32, f32) callconv(.c) c.CGError,
    SLSTransactionSetWindowSystemAlpha: *const fn (c.CFTypeRef, u32, f32) callconv(.c) c.CGError,

    // Window capture
    SLSHWCaptureWindowList: *const fn (c_int, [*]u32, c_int, u32) callconv(.c) c.CFArrayRef,

    // Window finding
    SLSFindWindowAndOwner: *const fn (c_int, c_int, c_int, c_int, *c.CGPoint, *c.CGPoint, *u32, *c_int) callconv(.c) c.c.OSStatus,

    pub fn init() !SkyLight {
        return SkyLight{
            // Connection management
            .SLSMainConnectionID = lookup(@TypeOf(@as(SkyLight, undefined).SLSMainConnectionID), "_SLSMainConnectionID") orelse return error.SymbolNotFound,
            .SLSNewConnection = lookup(@TypeOf(@as(SkyLight, undefined).SLSNewConnection), "_SLSNewConnection") orelse return error.SymbolNotFound,
            .SLSReleaseConnection = lookup(@TypeOf(@as(SkyLight, undefined).SLSReleaseConnection), "_SLSReleaseConnection") orelse return error.SymbolNotFound,
            .SLSRegisterConnectionNotifyProc = lookup(@TypeOf(@as(SkyLight, undefined).SLSRegisterConnectionNotifyProc), "_SLSRegisterConnectionNotifyProc") orelse return error.SymbolNotFound,
            .SLSGetConnectionPSN = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetConnectionPSN), "_SLSGetConnectionPSN") orelse return error.SymbolNotFound,
            .SLSConnectionGetPID = lookup(@TypeOf(@as(SkyLight, undefined).SLSConnectionGetPID), "_SLSConnectionGetPID") orelse return error.SymbolNotFound,
            .SLSGetConnectionIDForPSN = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetConnectionIDForPSN), "_SLSGetConnectionIDForPSN") orelse return error.SymbolNotFound,

            // Window geometry & properties
            .SLSGetWindowBounds = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetWindowBounds), "_SLSGetWindowBounds") orelse return error.SymbolNotFound,
            .SLSGetWindowLevel = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetWindowLevel), "_SLSGetWindowLevel") orelse return error.SymbolNotFound,
            .SLSGetWindowSubLevel = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetWindowSubLevel), "_SLSGetWindowSubLevel") orelse return error.SymbolNotFound,
            .SLSGetWindowAlpha = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetWindowAlpha), "_SLSGetWindowAlpha") orelse return error.SymbolNotFound,
            .SLSSetWindowAlpha = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowAlpha), "_SLSSetWindowAlpha") orelse return error.SymbolNotFound,
            .SLSSetWindowLevel = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowLevel), "_SLSSetWindowLevel") orelse return error.SymbolNotFound,
            .SLSSetWindowSubLevel = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowSubLevel), "_SLSSetWindowSubLevel") orelse return error.SymbolNotFound,
            .SLSSetWindowOpacity = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowOpacity), "_SLSSetWindowOpacity") orelse return error.SymbolNotFound,
            .SLSSetWindowResolution = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowResolution), "_SLSSetWindowResolution") orelse return error.SymbolNotFound,
            .SLSSetWindowTransform = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowTransform), "_SLSSetWindowTransform") orelse return error.SymbolNotFound,
            .SLSSetWindowBackgroundBlurRadiusStyle = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowBackgroundBlurRadiusStyle), "_SLSSetWindowBackgroundBlurRadiusStyle") orelse return error.SymbolNotFound,
            .SLSWindowSetShadowProperties = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowSetShadowProperties), "_SLSWindowSetShadowProperties") orelse return error.SymbolNotFound,
            .SLSCopyWindowProperty = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyWindowProperty), "_SLSCopyWindowProperty") orelse return error.SymbolNotFound,
            .SLSWindowIsOrderedIn = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIsOrderedIn), "_SLSWindowIsOrderedIn") orelse return error.SymbolNotFound,

            // Window ordering & movement
            .SLSOrderWindow = lookup(@TypeOf(@as(SkyLight, undefined).SLSOrderWindow), "_SLSOrderWindow") orelse return error.SymbolNotFound,
            .SLSMoveWindow = lookup(@TypeOf(@as(SkyLight, undefined).SLSMoveWindow), "_SLSMoveWindow") orelse return error.SymbolNotFound,
            .SLSMoveWindowWithGroup = lookup(@TypeOf(@as(SkyLight, undefined).SLSMoveWindowWithGroup), "_SLSMoveWindowWithGroup") orelse return error.SymbolNotFound,

            // Window tags
            .SLSSetWindowTags = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowTags), "_SLSSetWindowTags") orelse return error.SymbolNotFound,
            .SLSClearWindowTags = lookup(@TypeOf(@as(SkyLight, undefined).SLSClearWindowTags), "_SLSClearWindowTags") orelse return error.SymbolNotFound,

            // Window creation/destruction
            .SLSNewWindow = lookup(@TypeOf(@as(SkyLight, undefined).SLSNewWindow), "_SLSNewWindow") orelse return error.SymbolNotFound,
            .SLSNewWindowWithOpaqueShapeAndContext = lookup(@TypeOf(@as(SkyLight, undefined).SLSNewWindowWithOpaqueShapeAndContext), "_SLSNewWindowWithOpaqueShapeAndContext") orelse return error.SymbolNotFound,
            .SLSReleaseWindow = lookup(@TypeOf(@as(SkyLight, undefined).SLSReleaseWindow), "_SLSReleaseWindow") orelse return error.SymbolNotFound,
            .SLSSetWindowShape = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowShape), "_SLSSetWindowShape") orelse return error.SymbolNotFound,
            .CGSNewRegionWithRect = lookupCG(@TypeOf(@as(SkyLight, undefined).CGSNewRegionWithRect), "_CGSNewRegionWithRect") orelse return error.SymbolNotFound,

            // Window ownership
            .SLSGetWindowOwner = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetWindowOwner), "_SLSGetWindowOwner") orelse return error.SymbolNotFound,
            .SLSCopyAssociatedWindows = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyAssociatedWindows), "_SLSCopyAssociatedWindows") orelse return error.SymbolNotFound,

            // Window queries
            .SLSWindowQueryWindows = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowQueryWindows), "_SLSWindowQueryWindows") orelse return error.SymbolNotFound,
            .SLSWindowQueryResultCopyWindows = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowQueryResultCopyWindows), "_SLSWindowQueryResultCopyWindows") orelse return error.SymbolNotFound,
            .SLSWindowIteratorGetCount = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorGetCount), "_SLSWindowIteratorGetCount") orelse return error.SymbolNotFound,
            .SLSWindowIteratorAdvance = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorAdvance), "_SLSWindowIteratorAdvance") orelse return error.SymbolNotFound,
            .SLSWindowIteratorGetWindowID = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorGetWindowID), "_SLSWindowIteratorGetWindowID") orelse return error.SymbolNotFound,
            .SLSWindowIteratorGetParentID = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorGetParentID), "_SLSWindowIteratorGetParentID") orelse return error.SymbolNotFound,
            .SLSWindowIteratorGetLevel = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorGetLevel), "_SLSWindowIteratorGetLevel") orelse return error.SymbolNotFound,
            .SLSWindowIteratorGetTags = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorGetTags), "_SLSWindowIteratorGetTags") orelse return error.SymbolNotFound,
            .SLSWindowIteratorGetAttributes = lookup(@TypeOf(@as(SkyLight, undefined).SLSWindowIteratorGetAttributes), "_SLSWindowIteratorGetAttributes") orelse return error.SymbolNotFound,
            .SLSCopyWindowsWithOptionsAndTags = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyWindowsWithOptionsAndTags), "_SLSCopyWindowsWithOptionsAndTags") orelse return error.SymbolNotFound,

            // Window notifications
            .SLSRequestNotificationsForWindows = lookup(@TypeOf(@as(SkyLight, undefined).SLSRequestNotificationsForWindows), "_SLSRequestNotificationsForWindows") orelse return error.SymbolNotFound,

            // Display management
            .SLSCopyManagedDisplays = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyManagedDisplays), "_SLSCopyManagedDisplays") orelse return error.SymbolNotFound,
            .SLSCopyManagedDisplayForWindow = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyManagedDisplayForWindow), "_SLSCopyManagedDisplayForWindow") orelse return error.SymbolNotFound,
            .SLSCopyBestManagedDisplayForRect = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyBestManagedDisplayForRect), "_SLSCopyBestManagedDisplayForRect") orelse return error.SymbolNotFound,
            .SLSCopyBestManagedDisplayForPoint = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyBestManagedDisplayForPoint), "_SLSCopyBestManagedDisplayForPoint") orelse return error.SymbolNotFound,
            .SLSCopyActiveMenuBarDisplayIdentifier = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyActiveMenuBarDisplayIdentifier), "_SLSCopyActiveMenuBarDisplayIdentifier") orelse return error.SymbolNotFound,
            .SLSSetActiveMenuBarDisplayIdentifier = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetActiveMenuBarDisplayIdentifier), "_SLSSetActiveMenuBarDisplayIdentifier") orelse return error.SymbolNotFound,
            .SLSManagedDisplayIsAnimating = lookup(@TypeOf(@as(SkyLight, undefined).SLSManagedDisplayIsAnimating), "_SLSManagedDisplayIsAnimating") orelse return error.SymbolNotFound,
            .SLSGetDisplayMenubarHeight = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetDisplayMenubarHeight), "_SLSGetDisplayMenubarHeight") orelse return error.SymbolNotFound,
            .SLSGetDockRectWithReason = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetDockRectWithReason), "_SLSGetDockRectWithReason") orelse return error.SymbolNotFound,
            .SLSGetMenuBarAutohideEnabled = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetMenuBarAutohideEnabled), "_SLSGetMenuBarAutohideEnabled") orelse return error.SymbolNotFound,
            .SLSGetRevealedMenuBarBounds = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetRevealedMenuBarBounds), "_SLSGetRevealedMenuBarBounds") orelse return error.SymbolNotFound,
            .SLSSetMenuBarInsetAndAlpha = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetMenuBarInsetAndAlpha), "_SLSSetMenuBarInsetAndAlpha") orelse return error.SymbolNotFound,

            // Space management
            .SLSManagedDisplayGetCurrentSpace = lookup(@TypeOf(@as(SkyLight, undefined).SLSManagedDisplayGetCurrentSpace), "_SLSManagedDisplayGetCurrentSpace") orelse return error.SymbolNotFound,
            .SLSManagedDisplaySetCurrentSpace = lookup(@TypeOf(@as(SkyLight, undefined).SLSManagedDisplaySetCurrentSpace), "_SLSManagedDisplaySetCurrentSpace") orelse return error.SymbolNotFound,
            .SLSCopyManagedDisplaySpaces = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyManagedDisplaySpaces), "_SLSCopyManagedDisplaySpaces") orelse return error.SymbolNotFound,
            .SLSCopyManagedDisplayForSpace = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopyManagedDisplayForSpace), "_SLSCopyManagedDisplayForSpace") orelse return error.SymbolNotFound,
            .SLSCopySpacesForWindows = lookup(@TypeOf(@as(SkyLight, undefined).SLSCopySpacesForWindows), "_SLSCopySpacesForWindows") orelse return error.SymbolNotFound,
            .SLSSpaceGetType = lookup(@TypeOf(@as(SkyLight, undefined).SLSSpaceGetType), "_SLSSpaceGetType") orelse return error.SymbolNotFound,
            .SLSSpaceCopyName = lookup(@TypeOf(@as(SkyLight, undefined).SLSSpaceCopyName), "_SLSSpaceCopyName") orelse return error.SymbolNotFound,
            .SLSSpaceSetCompatID = lookup(@TypeOf(@as(SkyLight, undefined).SLSSpaceSetCompatID), "_SLSSpaceSetCompatID") orelse return error.SymbolNotFound,
            .SLSGetSpaceManagementMode = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetSpaceManagementMode), "_SLSGetSpaceManagementMode") orelse return error.SymbolNotFound,
            .SLSShowSpaces = lookup(@TypeOf(@as(SkyLight, undefined).SLSShowSpaces), "_SLSShowSpaces") orelse return error.SymbolNotFound,
            .SLSHideSpaces = lookup(@TypeOf(@as(SkyLight, undefined).SLSHideSpaces), "_SLSHideSpaces") orelse return error.SymbolNotFound,
            .SLSMoveWindowsToManagedSpace = lookup(@TypeOf(@as(SkyLight, undefined).SLSMoveWindowsToManagedSpace), "_SLSMoveWindowsToManagedSpace") orelse return error.SymbolNotFound,
            .SLSSetWindowListWorkspace = lookup(@TypeOf(@as(SkyLight, undefined).SLSSetWindowListWorkspace), "_SLSSetWindowListWorkspace") orelse return error.SymbolNotFound,

            // Process/space assignment
            .SLSProcessAssignToSpace = lookup(@TypeOf(@as(SkyLight, undefined).SLSProcessAssignToSpace), "_SLSProcessAssignToSpace") orelse return error.SymbolNotFound,
            .SLSProcessAssignToAllSpaces = lookup(@TypeOf(@as(SkyLight, undefined).SLSProcessAssignToAllSpaces), "_SLSProcessAssignToAllSpaces") orelse return error.SymbolNotFound,
            .SLSReassociateWindowsSpacesByGeometry = lookup(@TypeOf(@as(SkyLight, undefined).SLSReassociateWindowsSpacesByGeometry), "_SLSReassociateWindowsSpacesByGeometry") orelse return error.SymbolNotFound,

            // Cursor
            .SLSGetCurrentCursorLocation = lookup(@TypeOf(@as(SkyLight, undefined).SLSGetCurrentCursorLocation), "_SLSGetCurrentCursorLocation") orelse return error.SymbolNotFound,

            // Update control
            .SLSDisableUpdate = lookup(@TypeOf(@as(SkyLight, undefined).SLSDisableUpdate), "_SLSDisableUpdate") orelse return error.SymbolNotFound,
            .SLSReenableUpdate = lookup(@TypeOf(@as(SkyLight, undefined).SLSReenableUpdate), "_SLSReenableUpdate") orelse return error.SymbolNotFound,

            // Transactions
            .SLSTransactionCreate = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionCreate), "_SLSTransactionCreate") orelse return error.SymbolNotFound,
            .SLSTransactionCommit = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionCommit), "_SLSTransactionCommit") orelse return error.SymbolNotFound,
            .SLSTransactionSetWindowTransform = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionSetWindowTransform), "_SLSTransactionSetWindowTransform") orelse return error.SymbolNotFound,
            .SLSTransactionOrderWindow = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionOrderWindow), "_SLSTransactionOrderWindow") orelse return error.SymbolNotFound,
            .SLSTransactionOrderWindowGroup = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionOrderWindowGroup), "_SLSTransactionOrderWindowGroup") orelse return error.SymbolNotFound,
            .SLSTransactionSetWindowAlpha = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionSetWindowAlpha), "_SLSTransactionSetWindowAlpha") orelse return error.SymbolNotFound,
            .SLSTransactionSetWindowSystemAlpha = lookup(@TypeOf(@as(SkyLight, undefined).SLSTransactionSetWindowSystemAlpha), "_SLSTransactionSetWindowSystemAlpha") orelse return error.SymbolNotFound,

            // Window capture
            .SLSHWCaptureWindowList = lookup(@TypeOf(@as(SkyLight, undefined).SLSHWCaptureWindowList), "_SLSHWCaptureWindowList") orelse return error.SymbolNotFound,

            // Window finding
            .SLSFindWindowAndOwner = lookup(@TypeOf(@as(SkyLight, undefined).SLSFindWindowAndOwner), "_SLSFindWindowAndOwner") orelse return error.SymbolNotFound,
        };
    }
};

var skylight_instance: ?SkyLight = null;

pub fn get() !*const SkyLight {
    if (skylight_instance) |*sl| {
        return sl;
    }
    skylight_instance = try SkyLight.init();
    return &skylight_instance.?;
}

// ============================================================================
// Space type constants
// ============================================================================

pub const SpaceType = struct {
    pub const user: c_int = 0;
    pub const fullscreen: c_int = 4;
    pub const system: c_int = 2;
};

// ============================================================================
// Window ordering constants
// ============================================================================

pub const WindowOrder = struct {
    pub const out: c_int = 0;
    pub const above: c_int = 1;
    pub const below: c_int = -1;
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SkyLight.init succeeds" {
    // Integration test: requires SkyLight framework to be available
    const sl = try SkyLight.init();
    _ = sl;
}

test "SkyLight.get returns same instance" {
    const sl1 = try get();
    const sl2 = try get();
    try testing.expectEqual(sl1, sl2);
}

test "SkyLight.SLSMainConnectionID returns valid id" {
    const sl = try get();
    const cid = sl.SLSMainConnectionID();
    try testing.expect(cid > 0);
}

test "SpaceType constants" {
    try testing.expectEqual(@as(c_int, 0), SpaceType.user);
    try testing.expectEqual(@as(c_int, 4), SpaceType.fullscreen);
    try testing.expectEqual(@as(c_int, 2), SpaceType.system);
}

test "WindowOrder constants" {
    try testing.expectEqual(@as(c_int, 0), WindowOrder.out);
    try testing.expectEqual(@as(c_int, 1), WindowOrder.above);
    try testing.expectEqual(@as(c_int, -1), WindowOrder.below);
}
