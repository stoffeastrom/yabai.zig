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
    configure = 0x20, // Send discovered function addresses to payload
};

/// SA client for communicating with the injected payload
pub const Client = struct {
    socket_path_buf: [256]u8,
    socket_path_len: usize,

    pub fn init(socket_path: []const u8) Client {
        var client = Client{
            .socket_path_buf = undefined,
            .socket_path_len = @min(socket_path.len, 255),
        };
        @memcpy(client.socket_path_buf[0..client.socket_path_len], socket_path[0..client.socket_path_len]);
        client.socket_path_buf[client.socket_path_len] = 0;
        return client;
    }

    fn getSocketPath(self: *const Client) []const u8 {
        return self.socket_path_buf[0..self.socket_path_len];
    }

    /// Send a message to the SA and wait for acknowledgment
    fn send(self: *const Client, bytes: []const u8) bool {
        const socket_path = self.getSocketPath();
        log.debug("SA send: path={s} (len={})", .{ socket_path, socket_path.len });

        // Create socket
        const sockfd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
            log.debug("SA send: socket create failed: {}", .{err});
            return false;
        };
        defer std.posix.close(sockfd);

        // Set socket timeout (500ms for connect/send/recv)
        const timeout = std.posix.timeval{ .sec = 0, .usec = 500_000 };
        std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Connect to SA socket
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_len = @min(socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], socket_path[0..path_len]);

        std.posix.connect(sockfd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            log.debug("SA send: connect failed: {} (path={s})", .{ err, socket_path });
            return false;
        };

        // Send message
        _ = std.posix.send(sockfd, bytes, 0) catch |err| {
            log.debug("SA send: send failed: {}", .{err});
            return false;
        };

        // Wait for ack (single byte)
        var ack: [1]u8 = undefined;
        _ = std.posix.recv(sockfd, &ack, 0) catch |err| {
            log.debug("SA send: recv failed: {}", .{err});
            return false;
        };

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

    /// Response buffer for operations that return data
    const ResponseBuf = struct {
        data: [64]u8 = undefined,
        len: usize = 0,
    };

    /// Send a message and receive a multi-byte response
    fn sendMessageWithResponse(self: *const Client, opcode: Opcode, payload: []const u8) ?[]const u8 {
        const socket_path = self.getSocketPath();

        // Create socket
        const sockfd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
            log.debug("SA sendWithResponse: socket create failed: {}", .{err});
            return null;
        };
        defer std.posix.close(sockfd);

        // Set socket timeout
        const timeout = std.posix.timeval{ .sec = 1, .usec = 0 };
        std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Connect to SA socket
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_len = @min(socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], socket_path[0..path_len]);

        std.posix.connect(sockfd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            log.debug("SA sendWithResponse: connect failed: {}", .{err});
            return null;
        };

        // Build message
        var buf: [0x1000]u8 = undefined;
        const total_len = 2 + 1 + payload.len;
        const msg_len: i16 = @intCast(1 + payload.len);

        std.mem.writeInt(i16, buf[0..2], msg_len, .little);
        buf[2] = @intFromEnum(opcode);
        if (payload.len > 0) {
            @memcpy(buf[3..][0..payload.len], payload);
        }

        // Send message
        _ = std.posix.send(sockfd, buf[0..total_len], 0) catch |err| {
            log.debug("SA sendWithResponse: send failed: {}", .{err});
            return null;
        };

        // Receive response (up to 64 bytes)
        const response = &response_buf;
        response.len = std.posix.recv(sockfd, &response.data, 0) catch |err| {
            log.debug("SA sendWithResponse: recv failed: {}", .{err});
            return null;
        };

        if (response.len == 0) return null;
        return response.data[0..response.len];
    }

    // Thread-local response buffer to avoid returning stack pointer
    threadlocal var response_buf: ResponseBuf = .{};

    // ========================================================================
    // Configuration - send discovered addresses to payload
    // ========================================================================

    /// Configure payload with discovered function addresses
    /// Called once after injection to provide runtime-discovered Dock internals
    pub fn configure(self: *const Client, dock_spaces: u64, add_space: u64, remove_space: u64, move_space: u64) bool {
        var payload: [32]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], dock_spaces, .little);
        std.mem.writeInt(u64, payload[8..16], add_space, .little);
        std.mem.writeInt(u64, payload[16..24], remove_space, .little);
        std.mem.writeInt(u64, payload[24..32], move_space, .little);
        const result = self.sendMessage(.configure, &payload);
        if (result) {
            log.info("configured payload with addresses: dock_spaces=0x{x} add=0x{x} remove=0x{x} move=0x{x}", .{ dock_spaces, add_space, remove_space, move_space });
        } else {
            log.warn("failed to configure payload", .{});
        }
        return result;
    }

    // ========================================================================
    // Space operations
    // ========================================================================

    /// Create a new space on the same display as the given space
    /// Returns the new space ID on success, null on failure
    pub fn createSpace(self: *const Client, sid: u64) ?u64 {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, sid, .little);
        const response = self.sendMessageWithResponse(.space_create, &payload) orelse {
            log.warn("failed to create space (no response)", .{});
            return null;
        };
        if (response.len >= 8) {
            const result = std.mem.readInt(u64, response[0..8], .little);
            // Decode diagnostic codes from payload
            const diag = result >> 60;
            if (diag == 0x1) {
                log.warn("SA: no g_dock_spaces", .{});
                return null;
            } else if (diag == 0x2) {
                log.warn("SA: no g_add_space_fp", .{});
                return null;
            } else if (diag == 0x3) {
                log.warn("SA: no display_uuid for sid={}", .{sid});
                return null;
            } else if (diag == 0x4) {
                log.warn("SA: space count unchanged (before=after={}), add_space call failed", .{result & 0xFFFFFFFF});
                return null;
            } else if (result != 0) {
                log.info("created space {d} on display of space {d}", .{ result, sid });
                return result;
            }
        }
        log.warn("failed to create space (response=0x{x} len={d})", .{ if (response.len >= 8) std.mem.readInt(u64, response[0..8], .little) else 0, response.len });
        return null;
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
    /// prev_sid: If source space is active, switch to this space first (0 = source not active)
    pub fn moveSpaceAfterSpace(self: *const Client, src_sid: u64, dst_sid: u64, prev_sid: u64, focus: bool) bool {
        var payload: [25]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], src_sid, .little);
        std.mem.writeInt(u64, payload[8..16], dst_sid, .little);
        std.mem.writeInt(u64, payload[16..24], prev_sid, .little);
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
        const result = self.sendMessage(.window_to_space, &payload);
        if (!result) {
            log.warn("moveWindowToSpace failed: sid={} wid={}", .{ sid, wid });
        }
        return result;
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
