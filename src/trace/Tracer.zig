//! Perfetto-compatible tracing for yabai.zig
//!
//! Writes Chrome Trace Format JSON that can be loaded into ui.perfetto.dev
//!
//! Usage:
//!   const trace = @import("trace/Tracer.zig");
//!
//!   // Scoped tracing (auto-ends on scope exit)
//!   {
//!       const span = trace.begin("layout_calculate", .layout);
//!       defer span.end();
//!       // ... do work
//!   }
//!
//!   // With arguments
//!   {
//!       const span = trace.beginArgs("window_move", .window, .{ .wid = 123, .space = 1 });
//!       defer span.end();
//!   }
//!
//!   // Instant events (single point in time)
//!   trace.instant("space_switch", .space, .{ .from = 1, .to = 2 });
//!
//!   // Dump to file for Perfetto
//!   trace.dumpToFile("/tmp/yabai-trace.json");

const std = @import("std");
const builtin = @import("builtin");

/// Whether tracing is enabled (compile-time switch)
pub const enabled = builtin.mode == .Debug or @import("build_options").enable_tracing;

/// Trace categories for filtering in Perfetto
pub const Category = enum {
    window, // Window operations
    space, // Space management
    layout, // Layout calculations
    display, // Display events
    ipc, // IPC commands
    event, // Event loop/callbacks
    config, // Config loading/hotload
    mouse, // Focus follows mouse
    ax, // Accessibility operations

    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }
};

/// Event phase (Chrome Trace Format)
const Phase = enum(u8) {
    begin = 'B',
    end = 'E',
    complete = 'X',
    instant = 'i',
    counter = 'C',
    async_begin = 'b',
    async_end = 'e',
    flow_start = 's',
    flow_end = 'f',
};

/// A recorded trace event
const Event = struct {
    name_idx: u16, // Index into name pool
    cat: Category,
    phase: Phase,
    ts: i64, // Microseconds
    dur: i64 = 0, // Duration for complete events
    tid: u32, // Thread ID
    // Inline args (avoid allocations)
    arg0_key: u8 = 0, // Index into arg_keys
    arg0_val: i64 = 0,
    arg1_key: u8 = 0,
    arg1_val: i64 = 0,
};

/// Span handle returned by begin()
pub const Span = struct {
    start_ts: i64,
    name_idx: u16,
    cat: Category,
    tid: u32,

    pub fn end(self: Span) void {
        if (!enabled) return;
        global.endSpan(self);
    }

    /// End with additional arguments
    pub fn endArgs(self: Span, args: anytype) void {
        if (!enabled) return;
        global.endSpanArgs(self, args);
    }
};

/// Name string pool (avoid per-event allocations)
const NamePool = struct {
    names: [256][]const u8 = undefined,
    count: u16 = 0,

    fn intern(self: *NamePool, name: []const u8) u16 {
        // Check if already interned
        for (self.names[0..self.count], 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        // Add new
        if (self.count < 256) {
            self.names[self.count] = name;
            self.count += 1;
            return self.count - 1;
        }
        return 0; // Fallback to first
    }

    fn get(self: *const NamePool, idx: u16) []const u8 {
        if (idx < self.count) return self.names[idx];
        return "unknown";
    }
};

/// Argument key names (compact encoding)
const arg_keys = [_][]const u8{
    "", // 0 = unused
    "wid",
    "pid",
    "space",
    "display",
    "count",
    "duration_ms",
    "from",
    "to",
    "x",
    "y",
    "w",
    "h",
    "result",
    "error",
    "cmd",
};

/// Global tracer state
const GlobalTracer = struct {
    events: [8192]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    names: NamePool = .{},
    start_time: i64 = 0,
    pid: u32 = 0,
    mu: std.Thread.Mutex = .{},

    fn init(self: *GlobalTracer) void {
        self.start_time = std.time.microTimestamp();
        self.pid = @intCast(std.c.getpid());
    }

    fn record(self: *GlobalTracer, event: Event) void {
        self.mu.lock();
        defer self.mu.unlock();

        const idx = (self.head + self.count) % self.events.len;
        self.events[idx] = event;

        if (self.count < self.events.len) {
            self.count += 1;
        } else {
            // Ring buffer full, advance head
            self.head = (self.head + 1) % self.events.len;
        }
    }

    fn beginSpan(self: *GlobalTracer, name: []const u8, cat: Category) Span {
        const ts = std.time.microTimestamp();
        const tid = std.Thread.getCurrentId();

        self.mu.lock();
        const name_idx = self.names.intern(name);
        self.mu.unlock();

        self.record(.{
            .name_idx = name_idx,
            .cat = cat,
            .phase = .begin,
            .ts = ts,
            .tid = @truncate(tid),
        });

        return .{
            .start_ts = ts,
            .name_idx = name_idx,
            .cat = cat,
            .tid = @truncate(tid),
        };
    }

    fn endSpan(self: *GlobalTracer, span: Span) void {
        const ts = std.time.microTimestamp();
        self.record(.{
            .name_idx = span.name_idx,
            .cat = span.cat,
            .phase = .end,
            .ts = ts,
            .tid = span.tid,
        });
    }

    fn endSpanArgs(self: *GlobalTracer, span: Span, args: anytype) void {
        const ts = std.time.microTimestamp();
        var event = Event{
            .name_idx = span.name_idx,
            .cat = span.cat,
            .phase = .end,
            .ts = ts,
            .tid = span.tid,
        };
        applyArgs(&event, args);
        self.record(event);
    }

    fn instantEvent(self: *GlobalTracer, name: []const u8, cat: Category, args: anytype) void {
        const ts = std.time.microTimestamp();
        const tid = std.Thread.getCurrentId();

        self.mu.lock();
        const name_idx = self.names.intern(name);
        self.mu.unlock();

        var event = Event{
            .name_idx = name_idx,
            .cat = cat,
            .phase = .instant,
            .ts = ts,
            .tid = @truncate(tid),
        };
        applyArgs(&event, args);
        self.record(event);
    }

    fn applyArgs(event: *Event, args: anytype) void {
        const fields = std.meta.fields(@TypeOf(args));
        inline for (fields, 0..) |field, i| {
            if (i >= 2) break; // Max 2 args
            const key_idx = findArgKey(field.name);
            const val = @field(args, field.name);
            const int_val: i64 = switch (@typeInfo(@TypeOf(val))) {
                .int, .comptime_int => @intCast(val),
                .float, .comptime_float => @intFromFloat(val),
                .bool => if (val) 1 else 0,
                .@"enum" => @intFromEnum(val),
                else => 0,
            };
            if (i == 0) {
                event.arg0_key = key_idx;
                event.arg0_val = int_val;
            } else {
                event.arg1_key = key_idx;
                event.arg1_val = int_val;
            }
        }
    }

    fn findArgKey(name: []const u8) u8 {
        for (arg_keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, name)) return @intCast(i);
        }
        return 0;
    }
};

var global: GlobalTracer = .{};

// ============================================================================
// Public API
// ============================================================================

/// Initialize the tracer (call once at startup)
pub fn init() void {
    if (!enabled) return;
    global.init();
}

/// Begin a traced span - returns handle, call .end() when done
pub fn begin(comptime name: []const u8, cat: Category) Span {
    if (!enabled) return .{ .start_ts = 0, .name_idx = 0, .cat = cat, .tid = 0 };
    return global.beginSpan(name, cat);
}

/// Begin a traced span with arguments
pub fn beginArgs(comptime name: []const u8, cat: Category, args: anytype) Span {
    if (!enabled) return .{ .start_ts = 0, .name_idx = 0, .cat = cat, .tid = 0 };
    const span = global.beginSpan(name, cat);
    // Record args on begin event (modify last recorded)
    global.mu.lock();
    defer global.mu.unlock();
    if (global.count > 0) {
        const idx = (global.head + global.count - 1) % global.events.len;
        GlobalTracer.applyArgs(&global.events[idx], args);
    }
    return span;
}

/// Record an instant event (single point in time)
pub fn instant(comptime name: []const u8, cat: Category, args: anytype) void {
    if (!enabled) return;
    global.instantEvent(name, cat, args);
}

/// Record a counter value
pub fn counter(comptime name: []const u8, value: i64) void {
    if (!enabled) return;
    const ts = std.time.microTimestamp();
    const tid = std.Thread.getCurrentId();

    global.mu.lock();
    const name_idx = global.names.intern(name);
    global.mu.unlock();

    global.record(.{
        .name_idx = name_idx,
        .cat = .event,
        .phase = .counter,
        .ts = ts,
        .tid = @truncate(tid),
        .arg0_key = 5, // "count"
        .arg0_val = value,
    });
}

/// Get the number of recorded events
pub fn eventCount() usize {
    if (!enabled) return 0;
    global.mu.lock();
    defer global.mu.unlock();
    return global.count;
}

/// Clear all recorded events
pub fn clear() void {
    if (!enabled) return;
    global.mu.lock();
    defer global.mu.unlock();
    global.count = 0;
    global.head = 0;
}

/// Write trace to a file in Chrome Trace Format JSON
pub fn dumpToFile(path: []const u8) !void {
    if (!enabled) return;

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buffered = std.io.bufferedWriter(file.writer());
    try writeJson(buffered.writer());
    try buffered.flush();
}

/// Write trace JSON to any writer
pub fn writeJson(writer: anytype) !void {
    global.mu.lock();
    defer global.mu.unlock();

    try writer.writeAll("[\n");

    var first = true;
    var i: usize = 0;
    while (i < global.count) : (i += 1) {
        const idx = (global.head + i) % global.events.len;
        const event = global.events[idx];

        if (!first) try writer.writeAll(",\n");
        first = false;

        try writer.writeAll("{");

        // name
        try writer.writeAll("\"name\":\"");
        try writer.writeAll(global.names.get(event.name_idx));
        try writer.writeAll("\",");

        // cat
        try writer.writeAll("\"cat\":\"");
        try writer.writeAll(event.cat.name());
        try writer.writeAll("\",");

        // ph
        try writer.print("\"ph\":\"{c}\",", .{@intFromEnum(event.phase)});

        // ts
        try writer.print("\"ts\":{d},", .{event.ts});

        // dur (for complete events)
        if (event.phase == .complete and event.dur > 0) {
            try writer.print("\"dur\":{d},", .{event.dur});
        }

        // pid/tid
        try writer.print("\"pid\":{d},\"tid\":{d}", .{ global.pid, event.tid });

        // args
        if (event.arg0_key != 0 or event.arg1_key != 0) {
            try writer.writeAll(",\"args\":{");
            var has_arg = false;
            if (event.arg0_key != 0 and event.arg0_key < arg_keys.len) {
                try writer.print("\"{s}\":{d}", .{ arg_keys[event.arg0_key], event.arg0_val });
                has_arg = true;
            }
            if (event.arg1_key != 0 and event.arg1_key < arg_keys.len) {
                if (has_arg) try writer.writeAll(",");
                try writer.print("\"{s}\":{d}", .{ arg_keys[event.arg1_key], event.arg1_val });
            }
            try writer.writeAll("}");
        }

        // instant event scope
        if (event.phase == .instant) {
            try writer.writeAll(",\"s\":\"g\""); // global scope
        }

        try writer.writeAll("}");
    }

    try writer.writeAll("\n]\n");
}

/// Write trace JSON to a buffer, returns bytes written
pub fn writeToBuffer(buf: []u8) ![]u8 {
    var fbs = std.io.fixedBufferStream(buf);
    try writeJson(fbs.writer());
    return fbs.getWritten();
}

// ============================================================================
// Build options (injected by build.zig)
// ============================================================================

const build_options = struct {
    pub const enable_tracing: bool = true; // Default on for now
};
