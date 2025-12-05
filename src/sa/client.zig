//! Scripting Addition client - communicates with SA payload injected into Dock
const std = @import("std");
const c = @import("../platform/c.zig");

const log = std.log.scoped(.sa_client);

/// SA opcodes for communication with injected payload
pub const Opcode = enum(u8) {
    handshake = 0x01,
    space_focus = 0x02,
    space_create = 0x03,
    space_destroy = 0x04,
    space_move = 0x05,
    window_move = 0x06,
    window_opacity = 0x07,
    window_opacity_fade = 0x08,
    window_layer = 0x09,
    window_sticky = 0x0a,
    window_shadow = 0x0b,
    window_focus = 0x0c,
    window_scale = 0x0d,
    window_swap_proxy_in = 0x0e,
    window_swap_proxy_out = 0x0f,
    window_order = 0x10,
    window_order_in = 0x11,
    window_list_to_space = 0x12,
    window_to_space = 0x13,
};

/// SA client for communicating with the injected payload
pub const Client = struct {
    socket_path: []const u8,

    pub fn init(socket_path: []const u8) Client {
        return .{ .socket_path = socket_path };
    }

    /// Send a message to the SA and wait for acknowledgment
    fn send(self: *const Client, bytes: []const u8) bool {
        // Create socket
        const sockfd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;
        defer std.posix.close(sockfd);

        // Connect to SA socket
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_len = @min(self.socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.socket_path[0..path_len]);

        std.posix.connect(sockfd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch return false;

        // Send message
        _ = std.posix.send(sockfd, bytes, 0) catch return false;

        // Wait for ack (single byte)
        var ack: [1]u8 = undefined;
        _ = std.posix.recv(sockfd, &ack, 0) catch return false;

        return true;
    }

    /// Build and send a message with the given opcode and payload
    fn sendMessage(self: *const Client, opcode: Opcode, payload: []const u8) bool {
        var buf: [0x1000]u8 = undefined;

        // Message format: [length: i16][opcode: u8][payload...]
        // length = total size - sizeof(length)
        const total_len = 2 + 1 + payload.len; // length field + opcode + payload
        const msg_len: i16 = @intCast(1 + payload.len); // opcode + payload

        std.mem.writeInt(i16, buf[0..2], msg_len, .little);
        buf[2] = @intFromEnum(opcode);
        if (payload.len > 0) {
            @memcpy(buf[3..][0..payload.len], payload);
        }

        return self.send(buf[0..total_len]);
    }

    // ========================================================================
    // Space operations
    // ========================================================================

    /// Create a new space on the same display as the given space
    pub fn createSpace(self: *const Client, sid: u64) bool {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, sid, .little);
        const result = self.sendMessage(.space_create, &payload);
        if (result) {
            log.info("created space on display of space {d}", .{sid});
        } else {
            log.warn("failed to create space", .{});
        }
        return result;
    }

    /// Destroy a space
    pub fn destroySpace(self: *const Client, sid: u64) bool {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, sid, .little);
        const result = self.sendMessage(.space_destroy, &payload);
        if (result) {
            log.info("destroyed space {d}", .{sid});
        } else {
            log.warn("failed to destroy space {d}", .{sid});
        }
        return result;
    }

    /// Focus a space
    pub fn focusSpace(self: *const Client, sid: u64) bool {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, sid, .little);
        return self.sendMessage(.space_focus, &payload);
    }

    /// Move space after another space
    pub fn moveSpaceAfterSpace(self: *const Client, src_sid: u64, dst_sid: u64, focus: bool) bool {
        var payload: [25]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], src_sid, .little);
        std.mem.writeInt(u64, payload[8..16], dst_sid, .little);
        std.mem.writeInt(u64, payload[16..24], 0, .little); // dummy_sid
        payload[24] = if (focus) 1 else 0;
        return self.sendMessage(.space_move, &payload);
    }

    // ========================================================================
    // Window operations
    // ========================================================================

    /// Move window to position
    pub fn moveWindow(self: *const Client, wid: u32, x: i32, y: i32) bool {
        var payload: [12]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid, .little);
        std.mem.writeInt(i32, payload[4..8], x, .little);
        std.mem.writeInt(i32, payload[8..12], y, .little);
        return self.sendMessage(.window_move, &payload);
    }

    /// Set window opacity
    pub fn setWindowOpacity(self: *const Client, wid: u32, opacity: f32) bool {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid, .little);
        @memcpy(payload[4..8], std.mem.asBytes(&opacity));
        return self.sendMessage(.window_opacity, &payload);
    }

    /// Set window opacity with fade
    pub fn setWindowOpacityFade(self: *const Client, wid: u32, opacity: f32, duration: f32) bool {
        var payload: [12]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid, .little);
        @memcpy(payload[4..8], std.mem.asBytes(&opacity));
        @memcpy(payload[8..12], std.mem.asBytes(&duration));
        return self.sendMessage(.window_opacity_fade, &payload);
    }

    /// Set window layer
    pub fn setWindowLayer(self: *const Client, wid: u32, layer: i32) bool {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid, .little);
        std.mem.writeInt(i32, payload[4..8], layer, .little);
        return self.sendMessage(.window_layer, &payload);
    }

    /// Set window sticky
    pub fn setWindowSticky(self: *const Client, wid: u32, sticky: bool) bool {
        var payload: [5]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid, .little);
        payload[4] = if (sticky) 1 else 0;
        return self.sendMessage(.window_sticky, &payload);
    }

    /// Set window shadow
    pub fn setWindowShadow(self: *const Client, wid: u32, shadow: bool) bool {
        var payload: [5]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid, .little);
        payload[4] = if (shadow) 1 else 0;
        return self.sendMessage(.window_shadow, &payload);
    }

    /// Focus window
    pub fn focusWindow(self: *const Client, wid: u32) bool {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, wid, .little);
        return self.sendMessage(.window_focus, &payload);
    }

    /// Move window to space
    pub fn moveWindowToSpace(self: *const Client, sid: u64, wid: u32) bool {
        var payload: [12]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], sid, .little);
        std.mem.writeInt(u32, payload[8..12], wid, .little);
        return self.sendMessage(.window_to_space, &payload);
    }

    /// Order window relative to another
    pub fn orderWindow(self: *const Client, wid_a: u32, order: i32, wid_b: u32) bool {
        var payload: [12]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], wid_a, .little);
        std.mem.writeInt(i32, payload[4..8], order, .little);
        std.mem.writeInt(u32, payload[8..12], wid_b, .little);
        return self.sendMessage(.window_order, &payload);
    }

    /// Check if SA is available by doing a handshake
    pub fn isAvailable(self: *const Client) bool {
        return self.sendMessage(.handshake, &.{});
    }
};
