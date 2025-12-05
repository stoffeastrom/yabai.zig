const std = @import("std");
const Event = @import("Event.zig").Event;

/// Thread-safe event queue with blocking dispatch
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(Event) = .{},
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) EventLoop {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.stop();
        self.queue.deinit(self.allocator);
    }

    /// Post an event to the queue (thread-safe)
    pub fn post(self: *EventLoop, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(self.allocator, event);
        self.condition.signal();
    }

    /// Get next event, blocking if queue is empty
    /// Returns null if loop is stopped
    pub fn next(self: *EventLoop) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len == 0) {
            if (!self.running.load(.acquire)) return null;
            self.condition.wait(&self.mutex);
        }

        return self.queue.orderedRemove(0);
    }

    /// Stop the event loop
    pub fn stop(self: *EventLoop) void {
        self.running.store(false, .release);
        self.mutex.lock();
        self.condition.broadcast();
        self.mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Check if loop is running
    pub fn isRunning(self: *EventLoop) bool {
        return self.running.load(.acquire);
    }

    /// Get number of pending events
    pub fn pending(self: *EventLoop) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EventLoop init/deinit" {
    var loop = EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    try std.testing.expect(!loop.isRunning());
    try std.testing.expectEqual(@as(usize, 0), loop.pending());
}

test "EventLoop post and pending" {
    var loop = EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    try loop.post(.{ .window_created = .{ .window_id = 1 } });
    try loop.post(.{ .window_created = .{ .window_id = 2 } });

    try std.testing.expectEqual(@as(usize, 2), loop.pending());
}

test "EventLoop next retrieves events in order" {
    var loop = EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    loop.running.store(true, .release);

    try loop.post(.{ .window_created = .{ .window_id = 1 } });
    try loop.post(.{ .window_created = .{ .window_id = 2 } });
    try loop.post(.{ .window_created = .{ .window_id = 3 } });

    const e1 = loop.next().?;
    try std.testing.expectEqual(@as(u32, 1), e1.window_created.window_id);

    const e2 = loop.next().?;
    try std.testing.expectEqual(@as(u32, 2), e2.window_created.window_id);

    const e3 = loop.next().?;
    try std.testing.expectEqual(@as(u32, 3), e3.window_created.window_id);

    try std.testing.expectEqual(@as(usize, 0), loop.pending());
}

test "EventLoop stop unblocks next" {
    var loop = EventLoop.init(std.testing.allocator);
    defer loop.deinit();

    loop.running.store(true, .release);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(l: *EventLoop) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            l.stop();
        }
    }.run, .{&loop});

    const result = loop.next();
    try std.testing.expectEqual(@as(?Event, null), result);

    thread.join();
}
