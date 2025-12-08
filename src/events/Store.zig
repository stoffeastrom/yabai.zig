const std = @import("std");
const Record = @import("Record.zig").Record;
const Event = @import("Event.zig").Event;

/// Event Store - records and replays events for testing
/// Uses JSONL format for human-readable storage
pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record),
    start_time: i128,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .records = .empty,
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.records.deinit(self.allocator);
    }

    /// Record an event
    pub fn recordEvent(self: *Self, event: Event) !void {
        try self.records.append(self.allocator, Record.fromEvent(self.start_time, event));
    }

    /// Get all recorded records
    pub fn getRecords(self: *const Self) []const Record {
        return self.records.items;
    }

    /// Save recording to JSONL file (human readable, one event per line)
    pub fn saveJsonl(self: *const Self, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        for (self.records.items) |rec| {
            const event = rec.payload.event;
            try writer.print("{{\"t\":{d},\"e\":\"{s}\"", .{ rec.timestamp_ns, @tagName(event.getType()) });
            try writeEventFields(writer, event);
            try writer.writeAll("}\n");
        }
        try file.writeAll(output.items);
    }

    /// Load recording from JSONL bytes (for @embedFile)
    pub fn loadJsonlFromBytes(allocator: std.mem.Allocator, data: []const u8) !Self {
        var store = Self{
            .allocator = allocator,
            .records = .empty,
            .start_time = 0,
        };
        errdefer store.deinit();

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (parseJsonlLine(line)) |rec| {
                try store.records.append(allocator, rec);
            }
        }

        return store;
    }

    fn writeEventFields(writer: anytype, event: Event) !void {
        switch (event) {
            .application_launched,
            .application_terminated,
            .application_front_switched,
            .application_activated,
            .application_deactivated,
            .application_visible,
            .application_hidden,
            => |app| {
                try writer.print(",\"pid\":{d}", .{app.pid});
            },
            .window_created,
            .window_destroyed,
            .window_focused,
            .window_moved,
            .window_resized,
            .window_minimized,
            .window_deminimized,
            .window_title_changed,
            .sls_window_ordered,
            .sls_window_destroyed,
            .menu_opened,
            .menu_closed,
            => |win| {
                try writer.print(",\"wid\":{d}", .{win.window_id});
                if (win.pid) |pid| try writer.print(",\"pid\":{d}", .{pid});
            },
            .space_created,
            .space_destroyed,
            .space_changed,
            => |space| {
                try writer.print(",\"sid\":{d}", .{space.space_id});
                if (space.display_id) |did| try writer.print(",\"did\":{d}", .{did});
            },
            .display_added,
            .display_removed,
            .display_moved,
            .display_resized,
            .display_changed,
            => |display| {
                try writer.print(",\"did\":{d}", .{display.display_id});
                if (display.flags != 0) try writer.print(",\"flags\":{d}", .{display.flags});
            },
            .mouse_down,
            .mouse_up,
            .mouse_dragged,
            .mouse_moved,
            => |mouse| {
                try writer.print(",\"x\":{d},\"y\":{d}", .{ @as(i64, @intFromFloat(mouse.point.x)), @as(i64, @intFromFloat(mouse.point.y)) });
                if (mouse.window_id) |wid| try writer.print(",\"wid\":{d}", .{wid});
                if (mouse.button != 0) try writer.print(",\"btn\":{d}", .{mouse.button});
            },
            else => {}, // void payloads - no extra fields
        }
    }

    fn parseJsonlLine(line: []const u8) ?Record {
        const timestamp_ns = parseJsonInt(line, "\"t\":") orelse return null;
        const event_name = parseJsonString(line, "\"e\":\"") orelse return null;
        const event: Event = parseEventFromJson(line, event_name) orelse return null;

        return Record{
            .timestamp_ns = timestamp_ns,
            .payload = .{ .event = event },
        };
    }

    fn parseEventFromJson(line: []const u8, event_name: []const u8) ?Event {
        if (std.mem.eql(u8, event_name, "application_launched")) {
            const pid = parseJsonInt(line, "\"pid\":") orelse return null;
            return Event{ .application_launched = .{ .pid = @intCast(pid) } };
        } else if (std.mem.eql(u8, event_name, "application_terminated")) {
            const pid = parseJsonInt(line, "\"pid\":") orelse return null;
            return Event{ .application_terminated = .{ .pid = @intCast(pid) } };
        } else if (std.mem.eql(u8, event_name, "application_front_switched")) {
            const pid = parseJsonInt(line, "\"pid\":") orelse return null;
            return Event{ .application_front_switched = .{ .pid = @intCast(pid) } };
        } else if (std.mem.eql(u8, event_name, "application_hidden")) {
            const pid = parseJsonInt(line, "\"pid\":") orelse return null;
            return Event{ .application_hidden = .{ .pid = @intCast(pid) } };
        } else if (std.mem.eql(u8, event_name, "application_visible")) {
            const pid = parseJsonInt(line, "\"pid\":") orelse return null;
            return Event{ .application_visible = .{ .pid = @intCast(pid) } };
        } else if (std.mem.eql(u8, event_name, "window_created")) {
            const wid = parseJsonInt(line, "\"wid\":") orelse return null;
            const pid = parseJsonInt(line, "\"pid\":");
            return Event{ .window_created = .{ .window_id = @intCast(wid), .pid = if (pid) |p| @intCast(p) else null } };
        } else if (std.mem.eql(u8, event_name, "window_destroyed")) {
            const wid = parseJsonInt(line, "\"wid\":") orelse return null;
            return Event{ .window_destroyed = .{ .window_id = @intCast(wid) } };
        } else if (std.mem.eql(u8, event_name, "window_focused")) {
            const wid = parseJsonInt(line, "\"wid\":") orelse return null;
            return Event{ .window_focused = .{ .window_id = @intCast(wid) } };
        } else if (std.mem.eql(u8, event_name, "window_minimized")) {
            const wid = parseJsonInt(line, "\"wid\":") orelse return null;
            return Event{ .window_minimized = .{ .window_id = @intCast(wid) } };
        } else if (std.mem.eql(u8, event_name, "window_deminimized")) {
            const wid = parseJsonInt(line, "\"wid\":") orelse return null;
            return Event{ .window_deminimized = .{ .window_id = @intCast(wid) } };
        } else if (std.mem.eql(u8, event_name, "space_changed")) {
            const sid = parseJsonInt(line, "\"sid\":") orelse return null;
            const did = parseJsonInt(line, "\"did\":");
            return Event{ .space_changed = .{ .space_id = @intCast(sid), .display_id = if (did) |d| @intCast(d) else null } };
        } else if (std.mem.eql(u8, event_name, "display_changed")) {
            const did = parseJsonInt(line, "\"did\":") orelse return null;
            return Event{ .display_changed = .{ .display_id = @intCast(did) } };
        } else if (std.mem.eql(u8, event_name, "system_woke")) {
            return Event{ .system_woke = {} };
        } else if (std.mem.eql(u8, event_name, "dock_did_restart")) {
            return Event{ .dock_did_restart = {} };
        }
        return null;
    }

    fn parseJsonInt(line: []const u8, key: []const u8) ?u64 {
        const start = std.mem.indexOf(u8, line, key) orelse return null;
        const num_start = start + key.len;
        var num_end = num_start;
        while (num_end < line.len and (line[num_end] >= '0' and line[num_end] <= '9')) : (num_end += 1) {}
        if (num_end == num_start) return null;
        return std.fmt.parseInt(u64, line[num_start..num_end], 10) catch null;
    }

    fn parseJsonString(line: []const u8, key: []const u8) ?[]const u8 {
        const start = std.mem.indexOf(u8, line, key) orelse return null;
        const str_start = start + key.len;
        const str_end = std.mem.indexOfScalarPos(u8, line, str_start, '"') orelse return null;
        return line[str_start..str_end];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Store init and record" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    try store.recordEvent(Event{ .window_created = .{ .window_id = 123 } });
    try store.recordEvent(Event{ .window_focused = .{ .window_id = 123 } });

    try std.testing.expectEqual(@as(usize, 2), store.getRecords().len);
}

test "Store JSONL roundtrip" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    try store.recordEvent(Event{ .application_launched = .{ .pid = 1234 } });
    try store.recordEvent(Event{ .window_created = .{ .window_id = 100, .pid = 1234 } });
    try store.recordEvent(Event{ .window_focused = .{ .window_id = 100 } });

    // Save to JSONL
    const path = "/tmp/yabai_jsonl_test.jsonl";
    try store.saveJsonl(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Load back
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(data);

    var loaded = try Store.loadJsonlFromBytes(allocator, data);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 3), loaded.getRecords().len);
}

test "Store load embedded JSONL fixture" {
    const allocator = std.testing.allocator;
    const DaemonMod = @import("../Daemon.zig");
    const Emulator = @import("Emulator.zig").Emulator;

    // Load from embedded test fixture
    const fixture = @embedFile("testdata/window_lifecycle.jsonl");
    var store = try Store.loadJsonlFromBytes(allocator, fixture);
    defer store.deinit();

    // Should have 7 events
    try std.testing.expectEqual(@as(usize, 7), store.getRecords().len);

    // Replay through daemon
    var emulator = Emulator.init(allocator);
    defer emulator.deinit();

    const mock = emulator.getMock();
    try mock.addDisplay(1, .{ .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .active_space_id = 1 });
    try mock.addSpace(1, .{ .display_id = 1, .space_type = .user, .is_active = true });

    var daemon = DaemonMod.Daemon.initForTest(allocator, emulator.platform());
    defer daemon.deinit();

    for (store.getRecords()) |rec| {
        daemon.processEvent(rec.payload.event);
    }

    // After full lifecycle, window should be gone
    try std.testing.expectEqual(@as(usize, 0), daemon.windows.count());
}
