const std = @import("std");
const Event = @import("Event.zig").Event;

/// A timestamped record for event sourcing.
pub const Record = struct {
    /// Monotonic timestamp in nanoseconds from session start
    timestamp_ns: u64,
    /// The payload
    payload: Payload,

    pub const Payload = union(enum) {
        event: Event,
    };

    /// Space type enum used by Platform
    pub const SpaceType = enum(u8) {
        user,
        fullscreen,
        system,
    };

    /// Create a record from an Event
    pub fn fromEvent(start_time: i128, event: Event) Record {
        const current = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(@max(0, current - start_time));
        return .{ .timestamp_ns = elapsed, .payload = .{ .event = event } };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Record fromEvent" {
    const start = std.time.nanoTimestamp();
    const event = Event{ .window_created = .{ .window_id = 123 } };
    const record = Record.fromEvent(start, event);

    switch (record.payload) {
        .event => |e| {
            try std.testing.expectEqual(Event.Type.window_created, e.getType());
        },
    }
}
