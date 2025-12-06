///! JSON serialization for IPC responses
///!
///! Provides type-safe JSON generation for query responses with proper escaping.
const std = @import("std");

/// JSON writer that writes to a fixed buffer
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn getWritten(self: *const Writer) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn remaining(self: *const Writer) usize {
        return self.buf.len - self.pos;
    }

    // Primitive writes
    pub fn writeByte(self: *Writer, byte: u8) !void {
        if (self.pos >= self.buf.len) return error.BufferFull;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    pub fn writeBytes(self: *Writer, bytes: []const u8) !void {
        if (self.pos + bytes.len > self.buf.len) return error.BufferFull;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    // JSON structure
    pub fn beginObject(self: *Writer) !void {
        try self.writeByte('{');
    }

    pub fn endObject(self: *Writer) !void {
        try self.writeByte('}');
    }

    pub fn beginArray(self: *Writer) !void {
        try self.writeByte('[');
    }

    pub fn endArray(self: *Writer) !void {
        try self.writeByte(']');
    }

    pub fn comma(self: *Writer) !void {
        try self.writeByte(',');
    }

    pub fn newline(self: *Writer) !void {
        try self.writeByte('\n');
    }

    // JSON values
    pub fn writeNull(self: *Writer) !void {
        try self.writeBytes("null");
    }

    pub fn writeBool(self: *Writer, value: bool) !void {
        try self.writeBytes(if (value) "true" else "false");
    }

    pub fn writeInt(self: *Writer, value: anytype) !void {
        var num_buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return error.BufferFull;
        try self.writeBytes(num_str);
    }

    pub fn writeFloat(self: *Writer, value: anytype) !void {
        var num_buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d:.4}", .{value}) catch return error.BufferFull;
        try self.writeBytes(num_str);
    }

    /// Write a JSON string with proper escaping
    pub fn writeString(self: *Writer, value: []const u8) !void {
        try self.writeByte('"');
        for (value) |char| {
            switch (char) {
                '"' => try self.writeBytes("\\\""),
                '\\' => try self.writeBytes("\\\\"),
                '\n' => try self.writeBytes("\\n"),
                '\r' => try self.writeBytes("\\r"),
                '\t' => try self.writeBytes("\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    // Control characters as \u00XX (excluding \t, \n, \r)
                    var esc_buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&esc_buf, "\\u00{x:0>2}", .{char}) catch continue;
                    try self.writeBytes(&esc_buf);
                },
                else => try self.writeByte(char),
            }
        }
        try self.writeByte('"');
    }

    /// Write a key-value pair: "key":value
    pub fn writeKey(self: *Writer, key: []const u8) !void {
        try self.writeString(key);
        try self.writeByte(':');
    }

    /// Write "key":int
    pub fn writeKeyInt(self: *Writer, key: []const u8, value: anytype) !void {
        try self.writeKey(key);
        try self.writeInt(value);
    }

    /// Write "key":float
    pub fn writeKeyFloat(self: *Writer, key: []const u8, value: anytype) !void {
        try self.writeKey(key);
        try self.writeFloat(value);
    }

    /// Write "key":bool
    pub fn writeKeyBool(self: *Writer, key: []const u8, value: bool) !void {
        try self.writeKey(key);
        try self.writeBool(value);
    }

    /// Write "key":"string"
    pub fn writeKeyString(self: *Writer, key: []const u8, value: []const u8) !void {
        try self.writeKey(key);
        try self.writeString(value);
    }

    /// Write "key":null
    pub fn writeKeyNull(self: *Writer, key: []const u8) !void {
        try self.writeKey(key);
        try self.writeNull();
    }
};

/// Frame (rect) for JSON output
pub const Frame = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn write(self: Frame, w: *Writer) !void {
        try w.beginObject();
        try w.writeKeyFloat("x", self.x);
        try w.comma();
        try w.writeKeyFloat("y", self.y);
        try w.comma();
        try w.writeKeyFloat("w", self.w);
        try w.comma();
        try w.writeKeyFloat("h", self.h);
        try w.endObject();
    }
};

/// Window data for JSON output
pub const WindowInfo = struct {
    id: u32,
    pid: i32 = 0,
    app: []const u8 = "",
    title: []const u8 = "",
    frame: Frame = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    role: []const u8 = "",
    subrole: []const u8 = "",
    display: u32 = 0,
    space: u64 = 0,
    level: i32 = 0,
    sub_level: i32 = 0,
    layer: []const u8 = "normal",
    sub_layer: []const u8 = "normal",
    opacity: f32 = 1.0,
    split_type: []const u8 = "none",
    split_child: []const u8 = "none",
    stack_index: u32 = 0,
    can_move: bool = true,
    can_resize: bool = true,
    has_focus: bool = false,
    has_shadow: bool = true,
    has_parent_zoom: bool = false,
    has_fullscreen_zoom: bool = false,
    has_ax_reference: bool = false,
    is_native_fullscreen: bool = false,
    is_visible: bool = true,
    is_minimized: bool = false,
    is_hidden: bool = false,
    is_floating: bool = false,
    is_sticky: bool = false,
    is_grabbed: bool = false,

    pub fn write(self: WindowInfo, w: *Writer) !void {
        try w.beginObject();

        try w.writeKeyInt("id", self.id);
        try w.comma();
        try w.writeKeyInt("pid", self.pid);
        try w.comma();
        try w.writeKeyString("app", self.app);
        try w.comma();
        try w.writeKeyString("title", self.title);
        try w.comma();

        try w.writeKey("frame");
        try self.frame.write(w);
        try w.comma();

        try w.writeKeyString("role", self.role);
        try w.comma();
        try w.writeKeyString("subrole", self.subrole);
        try w.comma();
        try w.writeKeyInt("display", self.display);
        try w.comma();
        try w.writeKeyInt("space", self.space);
        try w.comma();
        try w.writeKeyInt("level", self.level);
        try w.comma();
        try w.writeKeyInt("sub-level", self.sub_level);
        try w.comma();
        try w.writeKeyString("layer", self.layer);
        try w.comma();
        try w.writeKeyString("sub-layer", self.sub_layer);
        try w.comma();
        try w.writeKeyFloat("opacity", self.opacity);
        try w.comma();
        try w.writeKeyString("split-type", self.split_type);
        try w.comma();
        try w.writeKeyString("split-child", self.split_child);
        try w.comma();
        try w.writeKeyInt("stack-index", self.stack_index);
        try w.comma();
        try w.writeKeyBool("can-move", self.can_move);
        try w.comma();
        try w.writeKeyBool("can-resize", self.can_resize);
        try w.comma();
        try w.writeKeyBool("has-focus", self.has_focus);
        try w.comma();
        try w.writeKeyBool("has-shadow", self.has_shadow);
        try w.comma();
        try w.writeKeyBool("has-parent-zoom", self.has_parent_zoom);
        try w.comma();
        try w.writeKeyBool("has-fullscreen-zoom", self.has_fullscreen_zoom);
        try w.comma();
        try w.writeKeyBool("has-ax-reference", self.has_ax_reference);
        try w.comma();
        try w.writeKeyBool("is-native-fullscreen", self.is_native_fullscreen);
        try w.comma();
        try w.writeKeyBool("is-visible", self.is_visible);
        try w.comma();
        try w.writeKeyBool("is-minimized", self.is_minimized);
        try w.comma();
        try w.writeKeyBool("is-hidden", self.is_hidden);
        try w.comma();
        try w.writeKeyBool("is-floating", self.is_floating);
        try w.comma();
        try w.writeKeyBool("is-sticky", self.is_sticky);
        try w.comma();
        try w.writeKeyBool("is-grabbed", self.is_grabbed);

        try w.endObject();
    }
};

/// Space data for JSON output
pub const SpaceInfo = struct {
    id: u64,
    uuid: []const u8 = "",
    index: u32 = 0,
    label: []const u8 = "",
    type: []const u8 = "user",
    display: u32 = 0,
    windows: []const u32 = &.{},
    first_window: u32 = 0,
    last_window: u32 = 0,
    has_focus: bool = false,
    is_visible: bool = false,
    is_native_fullscreen: bool = false,

    pub fn write(self: SpaceInfo, w: *Writer) !void {
        try w.beginObject();

        try w.writeKeyInt("id", self.id);
        try w.comma();
        try w.writeKeyString("uuid", self.uuid);
        try w.comma();
        try w.writeKeyInt("index", self.index);
        try w.comma();
        try w.writeKeyString("label", self.label);
        try w.comma();
        try w.writeKeyString("type", self.type);
        try w.comma();
        try w.writeKeyInt("display", self.display);
        try w.comma();

        // Windows array
        try w.writeKey("windows");
        try w.beginArray();
        for (self.windows, 0..) |wid, i| {
            if (i > 0) try w.comma();
            try w.writeInt(wid);
        }
        try w.endArray();
        try w.comma();

        try w.writeKeyInt("first-window", self.first_window);
        try w.comma();
        try w.writeKeyInt("last-window", self.last_window);
        try w.comma();
        try w.writeKeyBool("has-focus", self.has_focus);
        try w.comma();
        try w.writeKeyBool("is-visible", self.is_visible);
        try w.comma();
        try w.writeKeyBool("is-native-fullscreen", self.is_native_fullscreen);

        try w.endObject();
    }
};

/// Display data for JSON output
pub const DisplayInfo = struct {
    id: u32,
    uuid: []const u8 = "",
    index: u32 = 0,
    label: []const u8 = "",
    frame: Frame = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    spaces: []const u64 = &.{},
    has_focus: bool = false,

    pub fn write(self: DisplayInfo, w: *Writer) !void {
        try w.beginObject();

        try w.writeKeyInt("id", self.id);
        try w.comma();
        try w.writeKeyString("uuid", self.uuid);
        try w.comma();
        try w.writeKeyInt("index", self.index);
        try w.comma();
        try w.writeKeyString("label", self.label);
        try w.comma();

        try w.writeKey("frame");
        try self.frame.write(w);
        try w.comma();

        // Spaces array
        try w.writeKey("spaces");
        try w.beginArray();
        for (self.spaces, 0..) |sid, i| {
            if (i > 0) try w.comma();
            try w.writeInt(sid);
        }
        try w.endArray();
        try w.comma();

        try w.writeKeyBool("has-focus", self.has_focus);

        try w.endObject();
    }
};

/// Error response for JSON output
pub const ErrorInfo = struct {
    code: []const u8,
    message: []const u8,
    detail: ?[]const u8 = null,

    pub fn write(self: ErrorInfo, w: *Writer) !void {
        try w.beginObject();

        try w.writeKeyString("error", self.code);
        try w.comma();
        try w.writeKeyString("message", self.message);
        if (self.detail) |d| {
            try w.comma();
            try w.writeKeyString("detail", d);
        }

        try w.endObject();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Writer basic operations" {
    var buf: [1024]u8 = undefined;
    var w = Writer.init(&buf);

    try w.beginObject();
    try w.writeKeyInt("id", 42);
    try w.comma();
    try w.writeKeyString("name", "test");
    try w.endObject();

    try testing.expectEqualStrings("{\"id\":42,\"name\":\"test\"}", w.getWritten());
}

test "Writer string escaping" {
    var buf: [1024]u8 = undefined;
    var w = Writer.init(&buf);

    try w.writeString("hello\"world\\test\nnewline");

    try testing.expectEqualStrings("\"hello\\\"world\\\\test\\nnewline\"", w.getWritten());
}

test "Writer array" {
    var buf: [1024]u8 = undefined;
    var w = Writer.init(&buf);

    try w.beginArray();
    try w.writeInt(1);
    try w.comma();
    try w.writeInt(2);
    try w.comma();
    try w.writeInt(3);
    try w.endArray();

    try testing.expectEqualStrings("[1,2,3]", w.getWritten());
}

test "Writer bool and null" {
    var buf: [1024]u8 = undefined;
    var w = Writer.init(&buf);

    try w.beginObject();
    try w.writeKeyBool("active", true);
    try w.comma();
    try w.writeKeyBool("hidden", false);
    try w.comma();
    try w.writeKeyNull("data");
    try w.endObject();

    try testing.expectEqualStrings("{\"active\":true,\"hidden\":false,\"data\":null}", w.getWritten());
}

test "Writer float" {
    var buf: [1024]u8 = undefined;
    var w = Writer.init(&buf);

    try w.beginObject();
    try w.writeKeyFloat("x", 100.5);
    try w.comma();
    try w.writeKeyFloat("y", 200.0);
    try w.endObject();

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"x\":100.5") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"y\":200") != null);
}

test "Frame write" {
    var buf: [1024]u8 = undefined;
    var w = Writer.init(&buf);

    const frame = Frame{ .x = 10, .y = 20, .w = 100, .h = 200 };
    try frame.write(&w);

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"x\":10") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"y\":20") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"w\":100") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"h\":200") != null);
}

test "WindowInfo write" {
    var buf: [4096]u8 = undefined;
    var w = Writer.init(&buf);

    const info = WindowInfo{
        .id = 12345,
        .pid = 1000,
        .app = "Terminal",
        .title = "~/projects",
        .has_focus = true,
        .is_visible = true,
    };
    try info.write(&w);

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":12345") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"pid\":1000") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"app\":\"Terminal\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"has-focus\":true") != null);
}

test "SpaceInfo write" {
    var buf: [2048]u8 = undefined;
    var w = Writer.init(&buf);

    const windows = [_]u32{ 100, 200, 300 };
    const info = SpaceInfo{
        .id = 1,
        .index = 1,
        .label = "code",
        .display = 1,
        .windows = &windows,
        .first_window = 100,
        .last_window = 300,
        .has_focus = true,
        .is_visible = true,
    };
    try info.write(&w);

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"label\":\"code\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"windows\":[100,200,300]") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"has-focus\":true") != null);
}

test "DisplayInfo write" {
    var buf: [2048]u8 = undefined;
    var w = Writer.init(&buf);

    const spaces = [_]u64{ 1, 2, 3 };
    const info = DisplayInfo{
        .id = 1,
        .index = 1,
        .label = "main",
        .frame = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
        .spaces = &spaces,
        .has_focus = true,
    };
    try info.write(&w);

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"label\":\"main\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"spaces\":[1,2,3]") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"w\":1920") != null);
}

test "ErrorInfo write" {
    var buf: [512]u8 = undefined;
    var w = Writer.init(&buf);

    const err = ErrorInfo{
        .code = "window_not_found",
        .message = "window not found",
        .detail = "id 12345",
    };
    try err.write(&w);

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"error\":\"window_not_found\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"message\":\"window not found\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"detail\":\"id 12345\"") != null);
}

test "ErrorInfo write without detail" {
    var buf: [512]u8 = undefined;
    var w = Writer.init(&buf);

    const err = ErrorInfo{
        .code = "unknown_command",
        .message = "unknown command",
    };
    try err.write(&w);

    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\"detail\"") == null);
}

test "Writer buffer full error" {
    var buf: [10]u8 = undefined;
    var w = Writer.init(&buf);

    try w.writeBytes("0123456789"); // Fill buffer
    try testing.expectError(error.BufferFull, w.writeByte('x'));
}

test "empty array" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);

    try w.beginArray();
    try w.endArray();

    try testing.expectEqualStrings("[]", w.getWritten());
}

test "nested objects" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);

    try w.beginObject();
    try w.writeKey("window");
    try w.beginObject();
    try w.writeKeyInt("id", 1);
    try w.endObject();
    try w.endObject();

    try testing.expectEqualStrings("{\"window\":{\"id\":1}}", w.getWritten());
}

test "special characters in string" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);

    try w.writeString("tab:\there\r\nquote:\"done\"");

    // Verify escaping
    const written = w.getWritten();
    try testing.expect(std.mem.indexOf(u8, written, "\\t") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\\r") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\\\"") != null);
}
