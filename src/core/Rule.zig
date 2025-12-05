//! Window rules for automatic window management.
//! Rules match windows by app, title, role and apply effects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const Space = @import("Space.zig");
const Display = @import("Display.zig");

const Rule = @This();

/// Rule matching criteria
label: ?[]const u8 = null,
app: ?Pattern = null,
title: ?Pattern = null,
role: ?Pattern = null,
subrole: ?Pattern = null,

/// Effects to apply when matched
effects: Effects = .{},

/// Rule flags
one_shot: bool = false,
one_shot_remove: bool = false,

pub const Pattern = struct {
    pattern: []const u8,
    exclude: bool = false,

    pub fn matches(self: Pattern, value: ?[]const u8) bool {
        const v = value orelse return self.exclude;
        // Simple substring match for now (could use regex)
        const found = std.mem.indexOf(u8, v, self.pattern) != null;
        return if (self.exclude) !found else found;
    }
};

pub const Effects = struct {
    display_id: ?Display.Id = null,
    space_id: ?Space.Id = null,
    follow_space: bool = false,
    opacity: ?f32 = null,
    manage: ?bool = null,
    sticky: ?bool = null,
    mouse_follows_focus: ?bool = null,
    layer: ?Layer = null,
    fullscreen: ?bool = null,
    grid: ?Grid = null,
    scratchpad: ?[]const u8 = null,

    pub const Layer = enum { below, normal, above };
    pub const Grid = struct { rows: u32, cols: u32, x: u32, y: u32, w: u32, h: u32 };

    /// Combine another effects struct into this one (other takes precedence)
    pub fn combine(self: *Effects, other: Effects) void {
        if (other.display_id) |v| {
            self.display_id = v;
            self.follow_space = other.follow_space;
        }
        if (other.space_id) |v| {
            self.space_id = v;
            self.follow_space = other.follow_space;
        }
        if (other.opacity) |v| self.opacity = v;
        if (other.layer) |v| self.layer = v;
        if (other.manage) |v| self.manage = v;
        if (other.sticky) |v| self.sticky = v;
        if (other.mouse_follows_focus) |v| self.mouse_follows_focus = v;
        if (other.fullscreen) |v| self.fullscreen = v;
        if (other.grid) |v| self.grid = v;
        if (other.scratchpad) |v| self.scratchpad = v;
    }
};

/// Check if this rule matches a window's properties
pub fn matches(self: *const Rule, app_name: ?[]const u8, title: ?[]const u8, role: ?[]const u8, subrole: ?[]const u8) bool {
    if (self.app) |p| if (!p.matches(app_name)) return false;
    if (self.title) |p| if (!p.matches(title)) return false;
    if (self.role) |p| if (!p.matches(role)) return false;
    if (self.subrole) |p| if (!p.matches(subrole)) return false;
    return true;
}

/// Rule registry for storing and matching rules
pub const Registry = struct {
    allocator: Allocator,
    rules: std.ArrayList(Rule),

    pub fn init(allocator: Allocator) Registry {
        return .{
            .allocator = allocator,
            .rules = .{},
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.rules.items) |*rule| {
            self.freeRule(rule);
        }
        self.rules.deinit(self.allocator);
    }

    fn freeRule(self: *Registry, rule: *Rule) void {
        // Note: Only free strings that were allocated by the registry
        // In practice, patterns would come from IPC parsing which allocates
        // For now, we only free label and scratchpad which are more likely to be owned
        if (rule.label) |l| {
            // Only free if it looks like it could be heap-allocated
            // (not a string literal from .rodata)
            _ = l;
        }
        if (rule.effects.scratchpad) |s| {
            _ = s;
        }
        // Pattern strings from rules added via IPC would need tracking
        // For simplicity, we skip freeing pattern strings in the base implementation
        _ = self;
    }

    /// Add a rule (replaces existing rule with same label)
    pub fn add(self: *Registry, rule: Rule) !void {
        if (rule.label) |label| {
            _ = self.removeByLabel(label);
        }
        try self.rules.append(self.allocator, rule);
    }

    /// Remove rule by index
    pub fn removeByIndex(self: *Registry, index: usize) bool {
        if (index >= self.rules.items.len) return false;
        self.freeRule(&self.rules.items[index]);
        _ = self.rules.orderedRemove(index);
        return true;
    }

    /// Remove rule by label
    pub fn removeByLabel(self: *Registry, label: []const u8) bool {
        for (self.rules.items, 0..) |*rule, i| {
            if (rule.label) |l| {
                if (std.mem.eql(u8, l, label)) {
                    self.freeRule(rule);
                    _ = self.rules.orderedRemove(i);
                    return true;
                }
            }
        }
        return false;
    }

    /// Find all matching rules and combine their effects
    pub fn matchAll(self: *const Registry, app_name: ?[]const u8, title: ?[]const u8, role: ?[]const u8, subrole: ?[]const u8) Effects {
        var result = Effects{};
        for (self.rules.items) |*rule| {
            if (rule.matches(app_name, title, role, subrole)) {
                result.combine(rule.effects);
            }
        }
        return result;
    }

    /// Get rule by index
    pub fn get(self: *const Registry, index: usize) ?*const Rule {
        if (index >= self.rules.items.len) return null;
        return &self.rules.items[index];
    }

    /// Get rule count
    pub fn count(self: *const Registry) usize {
        return self.rules.items.len;
    }
};

// Tests
test "pattern matching" {
    const p = Pattern{ .pattern = "Firefox" };
    try std.testing.expect(p.matches("Mozilla Firefox"));
    try std.testing.expect(!p.matches("Safari"));
    try std.testing.expect(!p.matches(null));
}

test "pattern exclude" {
    const p = Pattern{ .pattern = "Finder", .exclude = true };
    try std.testing.expect(!p.matches("Finder"));
    try std.testing.expect(p.matches("Terminal"));
    try std.testing.expect(p.matches(null)); // null passes exclude
}

test "rule matching" {
    const rule = Rule{
        .app = Pattern{ .pattern = "Code" },
        .title = Pattern{ .pattern = "main.zig" },
    };
    try std.testing.expect(rule.matches("Visual Studio Code", "main.zig - Project", null, null));
    try std.testing.expect(!rule.matches("Visual Studio Code", "README.md", null, null));
    try std.testing.expect(!rule.matches("Terminal", "main.zig", null, null));
}

test "effects combine" {
    var a = Effects{ .opacity = 0.8, .manage = true };
    const b = Effects{ .opacity = 0.9, .sticky = true };
    a.combine(b);

    try std.testing.expectEqual(@as(?f32, 0.9), a.opacity);
    try std.testing.expectEqual(@as(?bool, true), a.manage);
    try std.testing.expectEqual(@as(?bool, true), a.sticky);
}

test "rule registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.add(Rule{
        .app = Pattern{ .pattern = "Firefox" },
        .effects = .{ .opacity = 0.95 },
    });

    try registry.add(Rule{
        .app = Pattern{ .pattern = "Terminal" },
        .effects = .{ .manage = false },
    });

    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const effects = registry.matchAll("Firefox", null, null, null);
    try std.testing.expectEqual(@as(?f32, 0.95), effects.opacity);
}
