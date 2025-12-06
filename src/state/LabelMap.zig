const std = @import("std");

/// A bidirectional label map that owns its string keys.
/// Maps between an ID type and owned label strings.
/// Handles all memory management automatically.
///
/// This is designed for small collections (displays, spaces) where
/// O(n) label lookup is acceptable for the benefit of simpler ownership.
pub fn LabelMap(comptime Id: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            id: Id,
            label: []const u8,
        };

        allocator: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(Entry) = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.label);
            }
            self.entries.deinit(self.allocator);
        }

        /// Set a label for an ID. Replaces any existing label for this ID.
        pub fn set(self: *Self, id: Id, label: []const u8) !void {
            // Check if ID already has a label
            for (self.entries.items) |*entry| {
                if (entry.id == id) {
                    // Replace existing label
                    self.allocator.free(entry.label);
                    entry.label = try self.allocator.dupe(u8, label);
                    return;
                }
            }

            // Add new entry
            const owned_label = try self.allocator.dupe(u8, label);
            errdefer self.allocator.free(owned_label);
            try self.entries.append(self.allocator, .{ .id = id, .label = owned_label });
        }

        /// Get ID for a label (O(n) lookup)
        pub fn getId(self: *const Self, label: []const u8) ?Id {
            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.label, label)) {
                    return entry.id;
                }
            }
            return null;
        }

        /// Get label for an ID (O(n) lookup)
        pub fn getLabel(self: *const Self, id: Id) ?[]const u8 {
            for (self.entries.items) |entry| {
                if (entry.id == id) {
                    return entry.label;
                }
            }
            return null;
        }

        /// Remove label for an ID
        pub fn remove(self: *Self, id: Id) bool {
            for (self.entries.items, 0..) |entry, i| {
                if (entry.id == id) {
                    self.allocator.free(entry.label);
                    _ = self.entries.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        /// Clear all labels
        pub fn clear(self: *Self) void {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.label);
            }
            self.entries.clearRetainingCapacity();
        }

        /// Get count of labels
        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// Get capacity (allocated slots)
        pub fn labelCapacity(self: *const Self) usize {
            return self.entries.capacity;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "LabelMap basic operations" {
    var map = LabelMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.set(1, "main");
    try map.set(2, "secondary");

    try std.testing.expectEqual(@as(?u32, 1), map.getId("main"));
    try std.testing.expectEqual(@as(?u32, 2), map.getId("secondary"));
    try std.testing.expectEqual(@as(?u32, null), map.getId("nonexistent"));

    try std.testing.expect(std.mem.eql(u8, "main", map.getLabel(1).?));
    try std.testing.expect(std.mem.eql(u8, "secondary", map.getLabel(2).?));
    try std.testing.expectEqual(@as(?[]const u8, null), map.getLabel(999));
}

test "LabelMap replace existing" {
    var map = LabelMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.set(1, "old");
    try std.testing.expect(std.mem.eql(u8, "old", map.getLabel(1).?));

    try map.set(1, "new");
    try std.testing.expect(std.mem.eql(u8, "new", map.getLabel(1).?));
    try std.testing.expectEqual(@as(?u32, null), map.getId("old"));
    try std.testing.expectEqual(@as(?u32, 1), map.getId("new"));

    try std.testing.expectEqual(@as(usize, 1), map.count());
}

test "LabelMap remove" {
    var map = LabelMap(u32).init(std.testing.allocator);
    defer map.deinit();

    try map.set(1, "test");
    try std.testing.expectEqual(@as(usize, 1), map.count());

    try std.testing.expect(map.remove(1));
    try std.testing.expectEqual(@as(usize, 0), map.count());
    try std.testing.expectEqual(@as(?u32, null), map.getId("test"));

    try std.testing.expect(!map.remove(1)); // Already removed
}

test "LabelMap no leaks on deinit" {
    var map = LabelMap(u64).init(std.testing.allocator);

    try map.set(100, "space_one");
    try map.set(200, "space_two");
    try map.set(300, "space_three");

    // Replace one
    try map.set(200, "space_two_updated");

    // Remove one
    _ = map.remove(300);

    // deinit should free remaining without leaks
    map.deinit();
}
