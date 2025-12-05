const std = @import("std");

/// A HashMap wrapper that automatically handles cleanup of values.
///
/// Cleanup is determined at comptime in this order:
/// 1. If `cleanup_fn` is provided, use it
/// 2. If V is a pointer and the pointee has `deinit`, call it and free
/// 3. If V has a `deinit` field/method, call it
/// 4. Otherwise, no cleanup (primitives, etc.)
///
/// This prevents memory leaks from:
/// - Forgetting to cleanup values on remove
/// - Overwriting existing entries without cleanup
/// - Forgetting to call deinit on the map itself
pub fn ManagedHashMap(comptime K: type, comptime V: type, comptime cleanup_fn: ?fn (V) void) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        inner: std.AutoHashMapUnmanaged(K, V) = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var it = self.inner.valueIterator();
            while (it.next()) |value_ptr| {
                cleanupValue(self.allocator, value_ptr.*);
            }
            self.inner.deinit(self.allocator);
        }

        /// Put a value, automatically cleaning up any existing value for this key.
        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.inner.getPtr(key)) |existing| {
                cleanupValue(self.allocator, existing.*);
            }
            try self.inner.put(self.allocator, key, value);
        }

        /// Remove a value, automatically cleaning it up.
        pub fn remove(self: *Self, key: K) bool {
            if (self.inner.fetchRemove(key)) |kv| {
                cleanupValue(self.allocator, kv.value);
                return true;
            }
            return false;
        }

        /// Remove and return without cleanup (caller takes ownership).
        pub fn fetchRemove(self: *Self, key: K) ?V {
            if (self.inner.fetchRemove(key)) |kv| {
                return kv.value;
            }
            return null;
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            return self.inner.getPtr(key);
        }

        pub fn getPtrConst(self: *const Self, key: K) ?*const V {
            return self.inner.getPtr(key);
        }

        pub fn get(self: *const Self, key: K) ?V {
            return self.inner.get(key);
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.inner.contains(key);
        }

        pub fn count(self: *const Self) usize {
            return self.inner.count();
        }

        pub fn capacity(self: *const Self) usize {
            return self.inner.capacity();
        }

        pub fn valueIterator(self: *Self) std.AutoHashMapUnmanaged(K, V).ValueIterator {
            return self.inner.valueIterator();
        }

        pub fn keyIterator(self: *Self) std.AutoHashMapUnmanaged(K, V).KeyIterator {
            return self.inner.keyIterator();
        }

        pub fn iterator(self: *Self) std.AutoHashMapUnmanaged(K, V).Iterator {
            return self.inner.iterator();
        }

        /// Get or put - returns pointer to existing or newly inserted value.
        /// Note: Does NOT cleanup on overwrite since this returns a pointer for modification.
        pub fn getOrPut(self: *Self, key: K) !std.AutoHashMapUnmanaged(K, V).GetOrPutResult {
            return self.inner.getOrPut(self.allocator, key);
        }

        fn cleanupValue(allocator: std.mem.Allocator, value: V) void {
            // Priority 1: explicit cleanup function
            if (cleanup_fn) |f| {
                f(value);
                return;
            }

            const info = @typeInfo(V);

            // Priority 2: pointer with deinit - call deinit only (it handles freeing)
            if (info == .pointer and info.pointer.size == .one) {
                const Child = info.pointer.child;
                if (@hasDecl(Child, "deinit")) {
                    value.deinit();
                    return;
                }
                // No deinit - just free the pointer
                allocator.destroy(value);
                return;
            }

            // Priority 3: optional pointer with deinit
            if (info == .optional) {
                if (value) |v| {
                    const child_info = @typeInfo(info.optional.child);
                    if (child_info == .pointer and child_info.pointer.size == .one) {
                        const Child = child_info.pointer.child;
                        if (@hasDecl(Child, "deinit")) {
                            v.deinit();
                            return;
                        }
                        allocator.destroy(v);
                    }
                }
                return;
            }

            // No cleanup for primitives
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ManagedHashMap basic operations" {
    var map = ManagedHashMap(u32, u32, null).init(std.testing.allocator);
    defer map.deinit();

    try map.put(1, 100);
    try map.put(2, 200);

    try std.testing.expectEqual(@as(?u32, 100), map.get(1));
    try std.testing.expectEqual(@as(?u32, 200), map.get(2));
    try std.testing.expectEqual(@as(usize, 2), map.count());

    try std.testing.expect(map.remove(1));
    try std.testing.expectEqual(@as(?u32, null), map.get(1));
}

test "ManagedHashMap with custom cleanup function" {
    const State = struct {
        var cleanup_count: u32 = 0;
    };

    const cleanup = struct {
        fn call(value: u32) void {
            _ = value;
            State.cleanup_count += 1;
        }
    }.call;

    State.cleanup_count = 0;

    var map = ManagedHashMap(u32, u32, cleanup).init(std.testing.allocator);
    defer map.deinit();

    try map.put(1, 100);
    try map.put(2, 200);

    // Overwrite triggers cleanup
    try map.put(1, 150);
    try std.testing.expectEqual(@as(u32, 1), State.cleanup_count);

    // Remove triggers cleanup
    _ = map.remove(2);
    try std.testing.expectEqual(@as(u32, 2), State.cleanup_count);

    // deinit triggers cleanup for remaining
}

test "ManagedHashMap pointer with deinit" {
    const Item = struct {
        data: []u8,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{
                .data = try allocator.alloc(u8, 100),
                .allocator = allocator,
            };
            return self;
        }

        // Self-freeing deinit (like View.deinit)
        fn deinit(self: *@This()) void {
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    };

    var map = ManagedHashMap(u32, *Item, null).init(std.testing.allocator);
    defer map.deinit();

    try map.put(1, try Item.init(std.testing.allocator));
    try map.put(2, try Item.init(std.testing.allocator));

    _ = map.remove(1);
    // deinit cleans up the rest - no leaks
}

test "ManagedHashMap fetchRemove for ownership transfer" {
    const Item = struct {
        value: u32,
        allocator: std.mem.Allocator,

        fn deinit(self: *@This()) void {
            self.allocator.destroy(self);
        }
    };

    var map = ManagedHashMap(u32, *Item, null).init(std.testing.allocator);
    defer map.deinit();

    const item = try std.testing.allocator.create(Item);
    item.* = .{ .value = 42, .allocator = std.testing.allocator };
    try map.put(1, item);

    // Take ownership - caller responsible for cleanup
    const taken = map.fetchRemove(1);
    try std.testing.expect(taken != null);
    try std.testing.expectEqual(@as(u32, 42), taken.?.value);

    taken.?.deinit();
}
