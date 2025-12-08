const std = @import("std");
const Store = @import("Store.zig").Store;
const Record = @import("Record.zig").Record;
const Event = @import("Event.zig").Event;
const Mock = @import("../platform/Mock.zig").Mock;
const Platform = @import("../platform/Platform.zig").Platform;

/// Emulator for replaying recorded events through a Mock platform.
/// Enables deterministic testing of event handling logic.
pub const Emulator = struct {
    allocator: std.mem.Allocator,
    mock: Mock,
    records: []const Record,
    current_index: usize = 0,

    /// Event handler callback type
    pub const EventHandler = *const fn (event: Event, platform: Platform, ctx: ?*anyopaque) void;

    const Self = @This();

    /// Create emulator from an existing store (copies records)
    pub fn fromStore(allocator: std.mem.Allocator, store: *Store) !Self {
        const records = try allocator.dupe(Record, store.getRecords());

        return Self{
            .allocator = allocator,
            .mock = Mock.init(allocator),
            .records = records,
        };
    }

    /// Create emulator with empty state (for manual setup)
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .mock = Mock.init(allocator),
            .records = &.{},
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.records.len > 0) {
            self.allocator.free(self.records);
        }
        self.mock.deinit();
    }

    /// Get the mock platform for direct manipulation in tests
    pub fn getMock(self: *Self) *Mock {
        return &self.mock;
    }

    /// Get the platform interface
    pub fn platform(self: *Self) Platform {
        return self.mock.platform();
    }

    /// Reset playback to beginning
    pub fn reset(self: *Self) void {
        self.current_index = 0;
        self.mock.clearCommands();
    }

    /// Get total number of records
    pub fn recordCount(self: *const Self) usize {
        return self.records.len;
    }

    /// Get current playback position
    pub fn position(self: *const Self) usize {
        return self.current_index;
    }

    /// Check if there are more records to replay
    pub fn hasMore(self: *const Self) bool {
        return self.current_index < self.records.len;
    }

    /// Step through one record, calling handler for events
    pub fn step(self: *Self, handler: EventHandler, ctx: ?*anyopaque) bool {
        if (!self.hasMore()) return false;

        const rec = self.records[self.current_index];
        self.current_index += 1;

        handler(rec.payload.event, self.mock.platform(), ctx);

        return true;
    }

    /// Replay all events, calling handler for each
    pub fn replayAll(self: *Self, handler: EventHandler, ctx: ?*anyopaque) void {
        while (self.step(handler, ctx)) {}
    }

    /// Replay events up to a specific timestamp (nanoseconds)
    pub fn replayUntil(self: *Self, timestamp_ns: u64, handler: EventHandler, ctx: ?*anyopaque) void {
        while (self.hasMore()) {
            const rec = self.records[self.current_index];
            if (rec.timestamp_ns > timestamp_ns) break;
            _ = self.step(handler, ctx);
        }
    }

    /// Get next record without advancing (peek)
    pub fn peek(self: *const Self) ?Record {
        if (!self.hasMore()) return null;
        return self.records[self.current_index];
    }

    /// Skip records that aren't events
    pub fn skipToNextEvent(self: *Self) ?Event {
        while (self.hasMore()) {
            const rec = self.records[self.current_index];
            self.current_index += 1;
            if (rec.payload == .event) {
                return rec.payload.event;
            }
        }
        return null;
    }

    /// Count events of a specific type
    pub fn countEvents(self: *const Self, event_type: Event.Type) usize {
        var count: usize = 0;
        for (self.records) |rec| {
            if (rec.payload == .event and rec.payload.event.getType() == event_type) {
                count += 1;
            }
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

fn testHandler(event: Event, platform: Platform, ctx: ?*anyopaque) void {
    _ = platform;
    const counter: *usize = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .window_created, .window_destroyed, .window_focused => counter.* += 1,
        else => {},
    }
}

test "Emulator basic replay" {
    const allocator = std.testing.allocator;

    // Create a store with some events
    var store = Store.init(allocator);
    defer store.deinit();

    try store.recordEvent(Event{ .window_created = .{ .window_id = 100 } });
    try store.recordEvent(Event{ .window_focused = .{ .window_id = 100 } });
    try store.recordEvent(Event{ .window_destroyed = .{ .window_id = 100 } });

    // Create emulator from store
    var emulator = try Emulator.fromStore(allocator, &store);
    defer emulator.deinit();

    var counter: usize = 0;
    emulator.replayAll(testHandler, &counter);

    try std.testing.expectEqual(@as(usize, 3), counter);
}

test "Emulator step-by-step" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    try store.recordEvent(Event{ .window_created = .{ .window_id = 1 } });
    try store.recordEvent(Event{ .window_created = .{ .window_id = 2 } });

    var emulator = try Emulator.fromStore(allocator, &store);
    defer emulator.deinit();

    try std.testing.expectEqual(@as(usize, 2), emulator.recordCount());
    try std.testing.expectEqual(@as(usize, 0), emulator.position());
    try std.testing.expect(emulator.hasMore());

    var counter: usize = 0;
    _ = emulator.step(testHandler, &counter);
    try std.testing.expectEqual(@as(usize, 1), emulator.position());
    try std.testing.expectEqual(@as(usize, 1), counter);

    _ = emulator.step(testHandler, &counter);
    try std.testing.expectEqual(@as(usize, 2), emulator.position());
    try std.testing.expect(!emulator.hasMore());
}

test "Emulator with mock platform" {
    const allocator = std.testing.allocator;

    var emulator = Emulator.init(allocator);
    defer emulator.deinit();

    // Manually set up mock state
    try emulator.getMock().addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 1,
    });
    try emulator.getMock().addSpace(1, .{ .display_id = 1 });
    try emulator.getMock().addWindow(100, .{
        .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .space_id = 1,
        .pid = 1234,
    });

    const p = emulator.platform();

    // Verify platform queries work
    try std.testing.expect(p.getWindowFrame(100) != null);
    try std.testing.expectEqual(@as(?u64, 1), p.getWindowSpace(100));
}

test "Emulator countEvents" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    try store.recordEvent(Event{ .window_created = .{ .window_id = 1 } });
    try store.recordEvent(Event{ .window_created = .{ .window_id = 2 } });
    try store.recordEvent(Event{ .window_focused = .{ .window_id = 1 } });
    try store.recordEvent(Event{ .window_destroyed = .{ .window_id = 2 } });

    var emulator = try Emulator.fromStore(allocator, &store);
    defer emulator.deinit();

    try std.testing.expectEqual(@as(usize, 2), emulator.countEvents(.window_created));
    try std.testing.expectEqual(@as(usize, 1), emulator.countEvents(.window_focused));
    try std.testing.expectEqual(@as(usize, 1), emulator.countEvents(.window_destroyed));
}

test "Emulator reset" {
    const allocator = std.testing.allocator;

    var store = Store.init(allocator);
    defer store.deinit();

    try store.recordEvent(Event{ .window_created = .{ .window_id = 1 } });

    var emulator = try Emulator.fromStore(allocator, &store);
    defer emulator.deinit();

    var counter: usize = 0;
    emulator.replayAll(testHandler, &counter);
    try std.testing.expectEqual(@as(usize, 1), counter);
    try std.testing.expect(!emulator.hasMore());

    emulator.reset();
    try std.testing.expect(emulator.hasMore());
    try std.testing.expectEqual(@as(usize, 0), emulator.position());
}

test "Emulator with Daemon integration" {
    const allocator = std.testing.allocator;
    const DaemonMod = @import("../Daemon.zig");

    // Setup mock with initial state
    var emulator = Emulator.init(allocator);
    defer emulator.deinit();

    const mock = emulator.getMock();
    try mock.addDisplay(1, .{
        .frame = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .active_space_id = 100,
    });
    try mock.addSpace(100, .{ .display_id = 1, .space_type = .user, .is_active = true });

    // Create daemon with mock platform
    var daemon = DaemonMod.Daemon.initForTest(allocator, emulator.platform());
    defer daemon.deinit();

    // Verify initial state
    try std.testing.expectEqual(@as(usize, 0), daemon.windows.count());

    // Process window creation event
    daemon.processEvent(.{ .window_created = .{ .window_id = 100, .pid = 1234 } });
    try std.testing.expectEqual(@as(usize, 1), daemon.windows.count());
    try std.testing.expect(daemon.windows.contains(100));

    // Process focus event
    daemon.processEvent(.{ .window_focused = .{ .window_id = 100 } });
    try std.testing.expectEqual(@as(?u32, 100), daemon.windows.getFocusedId());

    // Process window destruction
    daemon.processEvent(.{ .window_destroyed = .{ .window_id = 100 } });
    try std.testing.expectEqual(@as(usize, 0), daemon.windows.count());
}
