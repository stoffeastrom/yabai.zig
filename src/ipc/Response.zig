///! IPC Response types for consistent error handling
///!
///! All IPC responses should use these types to ensure:
///! - Consistent error message format
///! - Comptime validation of error codes
///! - Clear separation between user errors and internal errors
const std = @import("std");

/// Error category for consistent messaging
pub const ErrorCategory = enum {
    /// User provided invalid input
    invalid_input,
    /// Target (window/space/display) not found
    not_found,
    /// Operation not supported in current state
    not_supported,
    /// Operation failed due to system/API error
    system_error,
    /// Permission denied
    permission_denied,
    /// Internal error (should not happen)
    internal,
};

/// Standard error codes with comptime-validated messages
pub const ErrorCode = enum {
    // Input errors
    empty_command,
    unknown_domain,
    unknown_command,
    missing_argument,
    invalid_argument,
    invalid_selector,
    invalid_value,

    // Not found errors
    window_not_found,
    space_not_found,
    display_not_found,
    no_focused_window,
    no_focused_space,

    // State errors
    window_not_managed,
    space_not_visible,
    already_exists,

    // System errors
    ax_error,
    skylight_error,
    socket_error,

    // Permission errors
    sa_not_loaded,
    permission_denied,

    pub fn category(self: ErrorCode) ErrorCategory {
        return switch (self) {
            .empty_command, .unknown_domain, .unknown_command, .missing_argument, .invalid_argument, .invalid_selector, .invalid_value => .invalid_input,
            .window_not_found, .space_not_found, .display_not_found, .no_focused_window, .no_focused_space => .not_found,
            .window_not_managed, .space_not_visible, .already_exists => .not_supported,
            .ax_error, .skylight_error, .socket_error => .system_error,
            .sa_not_loaded, .permission_denied => .permission_denied,
        };
    }

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .empty_command => "empty command",
            .unknown_domain => "unknown domain",
            .unknown_command => "unknown command",
            .missing_argument => "missing argument",
            .invalid_argument => "invalid argument",
            .invalid_selector => "invalid selector",
            .invalid_value => "invalid value",
            .window_not_found => "window not found",
            .space_not_found => "space not found",
            .display_not_found => "display not found",
            .no_focused_window => "no focused window",
            .no_focused_space => "no focused space",
            .window_not_managed => "window not managed",
            .space_not_visible => "space not visible",
            .already_exists => "already exists",
            .ax_error => "accessibility error",
            .skylight_error => "system error",
            .socket_error => "socket error",
            .sa_not_loaded => "scripting addition not loaded",
            .permission_denied => "permission denied",
        };
    }
};

/// Structured error response
pub const Error = struct {
    code: ErrorCode,
    detail: ?[]const u8 = null,

    pub fn format(self: Error, buf: []u8) []const u8 {
        const base = self.code.message();
        if (self.detail) |detail| {
            return std.fmt.bufPrint(buf, "{s}: {s}", .{ base, detail }) catch base;
        }
        return base;
    }
};

/// Create an error with optional detail
pub fn err(code: ErrorCode) Error {
    return .{ .code = code };
}

/// Create an error with detail
pub fn errWithDetail(code: ErrorCode, detail: []const u8) Error {
    return .{ .code = code, .detail = detail };
}

// ============================================================================
// Tests
// ============================================================================

test "error code messages are consistent" {
    // Verify all error codes have messages (comptime check)
    inline for (std.meta.fields(ErrorCode)) |field| {
        const code: ErrorCode = @enumFromInt(field.value);
        const msg = code.message();
        try std.testing.expect(msg.len > 0);
    }
}

test "error code categories are assigned" {
    inline for (std.meta.fields(ErrorCode)) |field| {
        const code: ErrorCode = @enumFromInt(field.value);
        _ = code.category();
    }
}

test "error formatting" {
    var buf: [256]u8 = undefined;

    const e1 = err(.window_not_found);
    try std.testing.expectEqualStrings("window not found", e1.format(&buf));

    const e2 = errWithDetail(.invalid_value, "expected number");
    try std.testing.expectEqualStrings("invalid value: expected number", e2.format(&buf));
}
