const std = @import("std");
const Window = @import("../core/Window.zig");
const Space = @import("../core/Space.zig");
const Display = @import("../core/Display.zig");
const View = @import("../core/View.zig");

/// IPC message parser for yabai.zig commands
pub const Message = @This();

/// Command domain
pub const Domain = enum {
    config,
    display,
    space,
    window,
    query,
    rule,
    signal,
};

/// Window selector
pub const WindowSelector = union(enum) {
    id: Window.Id,
    focused,
    first,
    last,
    recent,
    largest,
    smallest,
    north,
    south,
    east,
    west,
    sibling,
    stack_next,
    stack_prev,

    pub fn parse(input: []const u8) ?WindowSelector {
        if (std.mem.eql(u8, input, "focused")) return .focused;
        if (std.mem.eql(u8, input, "first")) return .first;
        if (std.mem.eql(u8, input, "last")) return .last;
        if (std.mem.eql(u8, input, "recent")) return .recent;
        if (std.mem.eql(u8, input, "largest")) return .largest;
        if (std.mem.eql(u8, input, "smallest")) return .smallest;
        if (std.mem.eql(u8, input, "north")) return .north;
        if (std.mem.eql(u8, input, "south")) return .south;
        if (std.mem.eql(u8, input, "east")) return .east;
        if (std.mem.eql(u8, input, "west")) return .west;
        if (std.mem.eql(u8, input, "sibling")) return .sibling;
        if (std.mem.eql(u8, input, "stack.next")) return .stack_next;
        if (std.mem.eql(u8, input, "stack.prev")) return .stack_prev;

        // Try parsing as window ID
        const id = std.fmt.parseInt(Window.Id, input, 10) catch return null;
        return .{ .id = id };
    }
};

/// Space selector
pub const SpaceSelector = union(enum) {
    id: Space.Id,
    label: []const u8,
    focused,
    prev,
    next,
    first,
    last,
    recent,

    pub fn parse(input: []const u8) SpaceSelector {
        if (std.mem.eql(u8, input, "focused")) return .focused;
        if (std.mem.eql(u8, input, "prev")) return .prev;
        if (std.mem.eql(u8, input, "next")) return .next;
        if (std.mem.eql(u8, input, "first")) return .first;
        if (std.mem.eql(u8, input, "last")) return .last;
        if (std.mem.eql(u8, input, "recent")) return .recent;

        // Try parsing as space ID
        if (std.fmt.parseInt(Space.Id, input, 10)) |id| {
            return .{ .id = id };
        } else |_| {
            // Treat as label
            return .{ .label = input };
        }
    }
};

/// Display selector
pub const DisplaySelector = union(enum) {
    id: Display.Id,
    label: []const u8,
    focused,
    prev,
    next,
    first,
    last,
    recent,
    north,
    south,
    east,
    west,

    pub fn parse(input: []const u8) DisplaySelector {
        if (std.mem.eql(u8, input, "focused")) return .focused;
        if (std.mem.eql(u8, input, "prev")) return .prev;
        if (std.mem.eql(u8, input, "next")) return .next;
        if (std.mem.eql(u8, input, "first")) return .first;
        if (std.mem.eql(u8, input, "last")) return .last;
        if (std.mem.eql(u8, input, "recent")) return .recent;
        if (std.mem.eql(u8, input, "north")) return .north;
        if (std.mem.eql(u8, input, "south")) return .south;
        if (std.mem.eql(u8, input, "east")) return .east;
        if (std.mem.eql(u8, input, "west")) return .west;

        if (std.fmt.parseInt(Display.Id, input, 10)) |id| {
            return .{ .id = id };
        } else |_| {
            return .{ .label = input };
        }
    }
};

/// Window toggle property
pub const WindowToggle = enum {
    float,
    sticky,
    shadow,
    split,
    zoom_parent,
    zoom_fullscreen,
    native_fullscreen,
    pip,
    expose,

    pub fn parse(input: []const u8) ?WindowToggle {
        if (std.mem.eql(u8, input, "float")) return .float;
        if (std.mem.eql(u8, input, "sticky")) return .sticky;
        if (std.mem.eql(u8, input, "shadow")) return .shadow;
        if (std.mem.eql(u8, input, "split")) return .split;
        if (std.mem.eql(u8, input, "zoom-parent")) return .zoom_parent;
        if (std.mem.eql(u8, input, "zoom-fullscreen")) return .zoom_fullscreen;
        if (std.mem.eql(u8, input, "native-fullscreen")) return .native_fullscreen;
        if (std.mem.eql(u8, input, "pip")) return .pip;
        if (std.mem.eql(u8, input, "expose")) return .expose;
        return null;
    }
};

/// Parsed command
pub const Command = union(enum) {
    // Window commands
    window_focus: WindowSelector,
    window_close: WindowSelector,
    window_minimize: WindowSelector,
    window_deminimize: WindowSelector,
    window_swap: struct { src: WindowSelector, dst: WindowSelector },
    window_warp: struct { src: WindowSelector, dst: WindowSelector },
    window_stack: struct { src: WindowSelector, dst: WindowSelector },
    window_space: struct { window: WindowSelector, space: SpaceSelector },
    window_display: struct { window: WindowSelector, display: DisplaySelector },
    window_toggle: struct { window: WindowSelector, prop: WindowToggle },
    window_move: struct { window: WindowSelector, dx: f32, dy: f32, absolute: bool },
    window_resize: struct { window: WindowSelector, edge: []const u8, dx: f32, dy: f32 },
    window_ratio: struct { window: WindowSelector, action: []const u8, ratio: f32 },
    window_opacity: struct { window: WindowSelector, opacity: f32 },
    window_layer: struct { window: WindowSelector, layer: []const u8 },
    window_insert: struct { window: WindowSelector, dir: []const u8 },
    window_grid: struct { window: WindowSelector, grid: []const u8 },

    // Space commands
    space_focus: SpaceSelector,
    space_create: ?DisplaySelector,
    space_destroy: SpaceSelector,
    space_move: struct { src: SpaceSelector, dst: SpaceSelector },
    space_swap: struct { src: SpaceSelector, dst: SpaceSelector },
    space_display: struct { space: SpaceSelector, display: DisplaySelector },
    space_layout: struct { space: SpaceSelector, layout: View.Layout },
    space_label: struct { space: SpaceSelector, label: []const u8 },
    space_padding: struct { space: SpaceSelector, mode: []const u8, top: i32, bottom: i32, left: i32, right: i32 },
    space_gap: struct { space: SpaceSelector, mode: []const u8, gap: i32 },
    space_balance: SpaceSelector,
    space_mirror: struct { space: SpaceSelector, axis: []const u8 },
    space_rotate: struct { space: SpaceSelector, degrees: i32 },
    space_toggle: struct { space: SpaceSelector, prop: []const u8 },

    // Display commands
    display_focus: DisplaySelector,
    display_space: struct { display: DisplaySelector, space: SpaceSelector },
    display_label: struct { display: DisplaySelector, label: []const u8 },

    // Query commands
    query_windows: struct { space: ?SpaceSelector, display: ?DisplaySelector },
    query_spaces: struct { display: ?DisplaySelector },
    query_displays: void,

    // Config commands
    config_get: []const u8,
    config_set: struct { key: []const u8, value: []const u8 },

    // Rule commands
    rule_add: []const u8,
    rule_remove: []const u8,
    rule_list: void,

    // Signal commands
    signal_add: []const u8,
    signal_remove: []const u8,
    signal_list: void,
};

pub const ParseError = error{
    EmptyCommand,
    UnknownDomain,
    UnknownCommand,
    MissingArgument,
    InvalidArgument,
    InvalidSelector,
};

/// Parse a command string into a Command
pub fn parse(input: []const u8) ParseError!Command {
    var tokenizer = Tokenizer.init(input);
    return parseWithTokenizer(&tokenizer);
}

/// Parse a null-separated command (from IPC socket)
pub fn parseNullSeparated(input: []const u8) ParseError!Command {
    var tokenizer = Tokenizer.initNullSeparated(input);
    return parseWithTokenizer(&tokenizer);
}

fn parseWithTokenizer(tokenizer: *Tokenizer) ParseError!Command {
    const domain_str = tokenizer.next() orelse return error.EmptyCommand;

    const domain: Domain = blk: {
        if (std.mem.eql(u8, domain_str, "window")) break :blk .window;
        if (std.mem.eql(u8, domain_str, "space")) break :blk .space;
        if (std.mem.eql(u8, domain_str, "display")) break :blk .display;
        if (std.mem.eql(u8, domain_str, "query")) break :blk .query;
        if (std.mem.eql(u8, domain_str, "config")) break :blk .config;
        if (std.mem.eql(u8, domain_str, "rule")) break :blk .rule;
        if (std.mem.eql(u8, domain_str, "signal")) break :blk .signal;
        return error.UnknownDomain;
    };

    return switch (domain) {
        .window => parseWindowCommand(tokenizer),
        .space => parseSpaceCommand(tokenizer),
        .display => parseDisplayCommand(tokenizer),
        .query => parseQueryCommand(tokenizer),
        .config => parseConfigCommand(tokenizer),
        .rule => parseRuleCommand(tokenizer),
        .signal => parseSignalCommand(tokenizer),
    };
}

fn parseWindowCommand(tokenizer: *Tokenizer) ParseError!Command {
    // Get selector (default to focused)
    var selector: WindowSelector = .focused;
    var cmd_str: []const u8 = undefined;

    const first = tokenizer.next() orelse return error.MissingArgument;

    if (first.len > 0 and first[0] == '-') {
        cmd_str = first;
    } else {
        selector = WindowSelector.parse(first) orelse return error.InvalidSelector;
        cmd_str = tokenizer.next() orelse return error.MissingArgument;
    }

    if (std.mem.eql(u8, cmd_str, "--focus")) {
        const target_str = tokenizer.next() orelse return .{ .window_focus = selector };
        const target = WindowSelector.parse(target_str) orelse return error.InvalidSelector;
        return .{ .window_focus = target };
    }

    if (std.mem.eql(u8, cmd_str, "--close")) {
        return .{ .window_close = selector };
    }

    if (std.mem.eql(u8, cmd_str, "--minimize")) {
        return .{ .window_minimize = selector };
    }

    if (std.mem.eql(u8, cmd_str, "--deminimize")) {
        return .{ .window_deminimize = selector };
    }

    if (std.mem.eql(u8, cmd_str, "--swap")) {
        const target_str = tokenizer.next() orelse return error.MissingArgument;
        const target = WindowSelector.parse(target_str) orelse return error.InvalidSelector;
        return .{ .window_swap = .{ .src = selector, .dst = target } };
    }

    if (std.mem.eql(u8, cmd_str, "--warp")) {
        const target_str = tokenizer.next() orelse return error.MissingArgument;
        const target = WindowSelector.parse(target_str) orelse return error.InvalidSelector;
        return .{ .window_warp = .{ .src = selector, .dst = target } };
    }

    if (std.mem.eql(u8, cmd_str, "--stack")) {
        const target_str = tokenizer.next() orelse return error.MissingArgument;
        const target = WindowSelector.parse(target_str) orelse return error.InvalidSelector;
        return .{ .window_stack = .{ .src = selector, .dst = target } };
    }

    if (std.mem.eql(u8, cmd_str, "--space")) {
        const space_str = tokenizer.next() orelse return error.MissingArgument;
        return .{ .window_space = .{ .window = selector, .space = SpaceSelector.parse(space_str) } };
    }

    if (std.mem.eql(u8, cmd_str, "--display")) {
        const display_str = tokenizer.next() orelse return error.MissingArgument;
        return .{ .window_display = .{ .window = selector, .display = DisplaySelector.parse(display_str) } };
    }

    if (std.mem.eql(u8, cmd_str, "--toggle")) {
        const prop_str = tokenizer.next() orelse return error.MissingArgument;
        const prop = WindowToggle.parse(prop_str) orelse return error.InvalidArgument;
        return .{ .window_toggle = .{ .window = selector, .prop = prop } };
    }

    if (std.mem.eql(u8, cmd_str, "--opacity")) {
        const opacity_str = tokenizer.next() orelse return error.MissingArgument;
        const opacity = std.fmt.parseFloat(f32, opacity_str) catch return error.InvalidArgument;
        return .{ .window_opacity = .{ .window = selector, .opacity = opacity } };
    }

    if (std.mem.eql(u8, cmd_str, "--layer") or std.mem.eql(u8, cmd_str, "--sub-layer")) {
        const layer = tokenizer.next() orelse return error.MissingArgument;
        return .{ .window_layer = .{ .window = selector, .layer = layer } };
    }

    if (std.mem.eql(u8, cmd_str, "--insert")) {
        const dir = tokenizer.next() orelse return error.MissingArgument;
        return .{ .window_insert = .{ .window = selector, .dir = dir } };
    }

    if (std.mem.eql(u8, cmd_str, "--grid")) {
        const grid = tokenizer.next() orelse return error.MissingArgument;
        return .{ .window_grid = .{ .window = selector, .grid = grid } };
    }

    return error.UnknownCommand;
}

fn parseSpaceCommand(tokenizer: *Tokenizer) ParseError!Command {
    var selector: SpaceSelector = .focused;
    var cmd_str: []const u8 = undefined;

    const first = tokenizer.next() orelse return error.MissingArgument;

    if (first.len > 0 and first[0] == '-') {
        cmd_str = first;
    } else {
        selector = SpaceSelector.parse(first);
        cmd_str = tokenizer.next() orelse return error.MissingArgument;
    }

    if (std.mem.eql(u8, cmd_str, "--focus")) {
        const target_str = tokenizer.next() orelse return .{ .space_focus = selector };
        return .{ .space_focus = SpaceSelector.parse(target_str) };
    }

    if (std.mem.eql(u8, cmd_str, "--create")) {
        if (tokenizer.next()) |display_str| {
            return .{ .space_create = DisplaySelector.parse(display_str) };
        }
        return .{ .space_create = null };
    }

    if (std.mem.eql(u8, cmd_str, "--destroy")) {
        return .{ .space_destroy = selector };
    }

    if (std.mem.eql(u8, cmd_str, "--move")) {
        const target_str = tokenizer.next() orelse return error.MissingArgument;
        return .{ .space_move = .{ .src = selector, .dst = SpaceSelector.parse(target_str) } };
    }

    if (std.mem.eql(u8, cmd_str, "--swap")) {
        const target_str = tokenizer.next() orelse return error.MissingArgument;
        return .{ .space_swap = .{ .src = selector, .dst = SpaceSelector.parse(target_str) } };
    }

    if (std.mem.eql(u8, cmd_str, "--display")) {
        const display_str = tokenizer.next() orelse return error.MissingArgument;
        return .{ .space_display = .{ .space = selector, .display = DisplaySelector.parse(display_str) } };
    }

    if (std.mem.eql(u8, cmd_str, "--layout")) {
        const layout_str = tokenizer.next() orelse return error.MissingArgument;
        const layout: View.Layout = blk: {
            if (std.mem.eql(u8, layout_str, "bsp")) break :blk .bsp;
            if (std.mem.eql(u8, layout_str, "stack")) break :blk .stack;
            if (std.mem.eql(u8, layout_str, "float")) break :blk .float;
            return error.InvalidArgument;
        };
        return .{ .space_layout = .{ .space = selector, .layout = layout } };
    }

    if (std.mem.eql(u8, cmd_str, "--label")) {
        const label = tokenizer.next() orelse return error.MissingArgument;
        return .{ .space_label = .{ .space = selector, .label = label } };
    }

    if (std.mem.eql(u8, cmd_str, "--balance")) {
        return .{ .space_balance = selector };
    }

    if (std.mem.eql(u8, cmd_str, "--mirror")) {
        const axis = tokenizer.next() orelse return error.MissingArgument;
        return .{ .space_mirror = .{ .space = selector, .axis = axis } };
    }

    if (std.mem.eql(u8, cmd_str, "--rotate")) {
        const deg_str = tokenizer.next() orelse return error.MissingArgument;
        const degrees = std.fmt.parseInt(i32, deg_str, 10) catch return error.InvalidArgument;
        return .{ .space_rotate = .{ .space = selector, .degrees = degrees } };
    }

    if (std.mem.eql(u8, cmd_str, "--toggle")) {
        const prop = tokenizer.next() orelse return error.MissingArgument;
        return .{ .space_toggle = .{ .space = selector, .prop = prop } };
    }

    return error.UnknownCommand;
}

fn parseDisplayCommand(tokenizer: *Tokenizer) ParseError!Command {
    var selector: DisplaySelector = .focused;
    var cmd_str: []const u8 = undefined;

    const first = tokenizer.next() orelse return error.MissingArgument;

    if (first.len > 0 and first[0] == '-') {
        cmd_str = first;
    } else {
        selector = DisplaySelector.parse(first);
        cmd_str = tokenizer.next() orelse return error.MissingArgument;
    }

    if (std.mem.eql(u8, cmd_str, "--focus")) {
        const target_str = tokenizer.next() orelse return .{ .display_focus = selector };
        return .{ .display_focus = DisplaySelector.parse(target_str) };
    }

    if (std.mem.eql(u8, cmd_str, "--space")) {
        const space_str = tokenizer.next() orelse return error.MissingArgument;
        return .{ .display_space = .{ .display = selector, .space = SpaceSelector.parse(space_str) } };
    }

    if (std.mem.eql(u8, cmd_str, "--label")) {
        const label = tokenizer.next() orelse return error.MissingArgument;
        return .{ .display_label = .{ .display = selector, .label = label } };
    }

    return error.UnknownCommand;
}

fn parseQueryCommand(tokenizer: *Tokenizer) ParseError!Command {
    const cmd_str = tokenizer.next() orelse return error.MissingArgument;

    if (std.mem.eql(u8, cmd_str, "--windows")) {
        var space: ?SpaceSelector = null;
        var display: ?DisplaySelector = null;

        while (tokenizer.next()) |arg| {
            if (std.mem.eql(u8, arg, "--space")) {
                const s = tokenizer.next() orelse return error.MissingArgument;
                space = SpaceSelector.parse(s);
            } else if (std.mem.eql(u8, arg, "--display")) {
                const d = tokenizer.next() orelse return error.MissingArgument;
                display = DisplaySelector.parse(d);
            }
        }
        return .{ .query_windows = .{ .space = space, .display = display } };
    }

    if (std.mem.eql(u8, cmd_str, "--spaces")) {
        var display: ?DisplaySelector = null;

        while (tokenizer.next()) |arg| {
            if (std.mem.eql(u8, arg, "--display")) {
                const d = tokenizer.next() orelse return error.MissingArgument;
                display = DisplaySelector.parse(d);
            }
        }
        return .{ .query_spaces = .{ .display = display } };
    }

    if (std.mem.eql(u8, cmd_str, "--displays")) {
        return .{ .query_displays = {} };
    }

    return error.UnknownCommand;
}

fn parseConfigCommand(tokenizer: *Tokenizer) ParseError!Command {
    const key = tokenizer.next() orelse return error.MissingArgument;

    if (tokenizer.next()) |value| {
        return .{ .config_set = .{ .key = key, .value = value } };
    }

    return .{ .config_get = key };
}

fn parseRuleCommand(tokenizer: *Tokenizer) ParseError!Command {
    const cmd_str = tokenizer.next() orelse return error.MissingArgument;

    if (std.mem.eql(u8, cmd_str, "--add")) {
        const rule = tokenizer.rest() orelse return error.MissingArgument;
        return .{ .rule_add = rule };
    }

    if (std.mem.eql(u8, cmd_str, "--remove")) {
        const rule = tokenizer.next() orelse return error.MissingArgument;
        return .{ .rule_remove = rule };
    }

    if (std.mem.eql(u8, cmd_str, "--list")) {
        return .{ .rule_list = {} };
    }

    return error.UnknownCommand;
}

fn parseSignalCommand(tokenizer: *Tokenizer) ParseError!Command {
    const cmd_str = tokenizer.next() orelse return error.MissingArgument;

    if (std.mem.eql(u8, cmd_str, "--add")) {
        const signal = tokenizer.rest() orelse return error.MissingArgument;
        return .{ .signal_add = signal };
    }

    if (std.mem.eql(u8, cmd_str, "--remove")) {
        const signal = tokenizer.next() orelse return error.MissingArgument;
        return .{ .signal_remove = signal };
    }

    if (std.mem.eql(u8, cmd_str, "--list")) {
        return .{ .signal_list = {} };
    }

    return error.UnknownCommand;
}

/// Simple tokenizer for command parsing
/// Supports both whitespace-separated and null-separated input
const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    separator: Separator,

    const Separator = enum { whitespace, null_byte };

    pub fn init(input: []const u8) Tokenizer {
        return .{ .input = input, .pos = 0, .separator = .whitespace };
    }

    pub fn initNullSeparated(input: []const u8) Tokenizer {
        return .{ .input = input, .pos = 0, .separator = .null_byte };
    }

    pub fn next(self: *Tokenizer) ?[]const u8 {
        return switch (self.separator) {
            .whitespace => self.nextWhitespace(),
            .null_byte => self.nextNull(),
        };
    }

    fn nextWhitespace(self: *Tokenizer) ?[]const u8 {
        // Skip whitespace
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.input.len) return null;

        const start = self.pos;

        // Find end of token
        while (self.pos < self.input.len and !std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        return self.input[start..self.pos];
    }

    fn nextNull(self: *Tokenizer) ?[]const u8 {
        if (self.pos >= self.input.len) return null;

        const start = self.pos;
        const token = std.mem.sliceTo(self.input[start..], 0);

        if (token.len == 0 and self.pos < self.input.len) {
            // Empty string followed by null - skip it
            self.pos += 1;
            return self.nextNull();
        }

        self.pos += token.len;
        if (self.pos < self.input.len) self.pos += 1; // Skip null byte

        return if (token.len > 0) token else null;
    }

    pub fn rest(self: *Tokenizer) ?[]const u8 {
        return switch (self.separator) {
            .whitespace => self.restWhitespace(),
            .null_byte => self.restNull(),
        };
    }

    fn restWhitespace(self: *Tokenizer) ?[]const u8 {
        // Skip whitespace
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.input.len) return null;

        const result = self.input[self.pos..];
        self.pos = self.input.len;
        return result;
    }

    fn restNull(self: *Tokenizer) ?[]const u8 {
        if (self.pos >= self.input.len) return null;

        // For null-separated, return everything remaining (may contain nulls)
        const result = self.input[self.pos..];
        self.pos = self.input.len;
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Tokenizer" {
    var t = Tokenizer.init("window --focus north");
    try std.testing.expectEqualStrings("window", t.next().?);
    try std.testing.expectEqualStrings("--focus", t.next().?);
    try std.testing.expectEqualStrings("north", t.next().?);
    try std.testing.expect(t.next() == null);
}

test "parse window focus" {
    const cmd = try parse("window --focus north");
    switch (cmd) {
        .window_focus => |sel| try std.testing.expect(sel == .north),
        else => return error.TestFailed,
    }
}

test "parse window focus with selector" {
    const cmd = try parse("window 12345 --focus");
    switch (cmd) {
        .window_focus => |sel| {
            switch (sel) {
                .id => |id| try std.testing.expectEqual(@as(Window.Id, 12345), id),
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse space layout" {
    const cmd = try parse("space --layout bsp");
    switch (cmd) {
        .space_layout => |sl| try std.testing.expectEqual(View.Layout.bsp, sl.layout),
        else => return error.TestFailed,
    }
}

test "parse query windows" {
    const cmd = try parse("query --windows --space 1");
    switch (cmd) {
        .query_windows => |q| {
            try std.testing.expect(q.space != null);
            try std.testing.expect(q.display == null);
        },
        else => return error.TestFailed,
    }
}

test "parse config set" {
    const cmd = try parse("config layout bsp");
    switch (cmd) {
        .config_set => |c| {
            try std.testing.expectEqualStrings("layout", c.key);
            try std.testing.expectEqualStrings("bsp", c.value);
        },
        else => return error.TestFailed,
    }
}

test "parse config get" {
    const cmd = try parse("config layout");
    switch (cmd) {
        .config_get => |key| try std.testing.expectEqualStrings("layout", key),
        else => return error.TestFailed,
    }
}

test "WindowSelector.parse" {
    const focused = WindowSelector.parse("focused").?;
    try std.testing.expect(focused == .focused);

    const north = WindowSelector.parse("north").?;
    try std.testing.expect(north == .north);

    const id_sel = WindowSelector.parse("12345").?;
    switch (id_sel) {
        .id => |id| try std.testing.expectEqual(@as(Window.Id, 12345), id),
        else => return error.TestFailed,
    }
}

test "SpaceSelector.parse" {
    try std.testing.expect(SpaceSelector.parse("focused") == .focused);
    try std.testing.expect(SpaceSelector.parse("next") == .next);

    const id_sel = SpaceSelector.parse("3");
    switch (id_sel) {
        .id => |id| try std.testing.expectEqual(@as(Space.Id, 3), id),
        else => return error.TestFailed,
    }
}

// ============================================================================
// Null-separated parsing tests (IPC format)
// ============================================================================

test "Tokenizer null-separated" {
    // Simulates: "window\0--focus\0north\0"
    var t = Tokenizer.initNullSeparated("window\x00--focus\x00north\x00");
    try std.testing.expectEqualStrings("window", t.next().?);
    try std.testing.expectEqualStrings("--focus", t.next().?);
    try std.testing.expectEqualStrings("north", t.next().?);
    try std.testing.expect(t.next() == null);
}

test "parseNullSeparated window focus" {
    const cmd = try parseNullSeparated("window\x00--focus\x00north\x00");
    switch (cmd) {
        .window_focus => |sel| try std.testing.expect(sel == .north),
        else => return error.TestFailed,
    }
}

test "parseNullSeparated space layout" {
    const cmd = try parseNullSeparated("space\x00--layout\x00bsp\x00");
    switch (cmd) {
        .space_layout => |sl| try std.testing.expectEqual(View.Layout.bsp, sl.layout),
        else => return error.TestFailed,
    }
}

test "parseNullSeparated query windows with space filter" {
    const cmd = try parseNullSeparated("query\x00--windows\x00--space\x001\x00");
    switch (cmd) {
        .query_windows => |q| {
            try std.testing.expect(q.space != null);
            try std.testing.expect(q.display == null);
        },
        else => return error.TestFailed,
    }
}

test "parseNullSeparated config set" {
    const cmd = try parseNullSeparated("config\x00layout\x00bsp\x00");
    switch (cmd) {
        .config_set => |c| {
            try std.testing.expectEqualStrings("layout", c.key);
            try std.testing.expectEqualStrings("bsp", c.value);
        },
        else => return error.TestFailed,
    }
}

test "parse space focus by index" {
    const cmd = try parse("space --focus 1");
    switch (cmd) {
        .space_focus => |sel| {
            switch (sel) {
                .id => |id| try std.testing.expectEqual(@as(Space.Id, 1), id),
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse space focus next" {
    const cmd = try parse("space --focus next");
    switch (cmd) {
        .space_focus => |sel| try std.testing.expect(sel == .next),
        else => return error.TestFailed,
    }
}

test "parse space focus prev" {
    const cmd = try parse("space --focus prev");
    switch (cmd) {
        .space_focus => |sel| try std.testing.expect(sel == .prev),
        else => return error.TestFailed,
    }
}

test "parse space label" {
    const cmd = try parse("space 1 --label code");
    switch (cmd) {
        .space_label => |sl| {
            switch (sl.space) {
                .id => |id| try std.testing.expectEqual(@as(Space.Id, 1), id),
                else => return error.TestFailed,
            }
            try std.testing.expectEqualStrings("code", sl.label);
        },
        else => return error.TestFailed,
    }
}

test "parse space focus by label" {
    const cmd = try parse("space --focus myspace");
    switch (cmd) {
        .space_focus => |sel| {
            switch (sel) {
                .label => |label| try std.testing.expectEqualStrings("myspace", label),
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse display focus by index" {
    const cmd = try parse("display --focus 2");
    switch (cmd) {
        .display_focus => |sel| {
            switch (sel) {
                .id => |id| try std.testing.expectEqual(@as(Display.Id, 2), id),
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse display focus next" {
    const cmd = try parse("display --focus next");
    switch (cmd) {
        .display_focus => |sel| try std.testing.expect(sel == .next),
        else => return error.TestFailed,
    }
}

test "parse window close" {
    const cmd = try parse("window --close");
    switch (cmd) {
        .window_close => |sel| try std.testing.expect(sel == .focused),
        else => return error.TestFailed,
    }
}

test "parse window minimize" {
    const cmd = try parse("window --minimize");
    switch (cmd) {
        .window_minimize => |sel| try std.testing.expect(sel == .focused),
        else => return error.TestFailed,
    }
}

test "parse window toggle float" {
    const cmd = try parse("window --toggle float");
    switch (cmd) {
        .window_toggle => |t| {
            try std.testing.expect(t.window == .focused);
            try std.testing.expect(t.prop == .float);
        },
        else => return error.TestFailed,
    }
}

test "parse window space" {
    const cmd = try parse("window --space 3");
    switch (cmd) {
        .window_space => |ws| {
            try std.testing.expect(ws.window == .focused);
            switch (ws.space) {
                .id => |id| try std.testing.expectEqual(@as(Space.Id, 3), id),
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

test "parse window swap" {
    const cmd = try parse("window --swap west");
    switch (cmd) {
        .window_swap => |s| {
            try std.testing.expect(s.src == .focused);
            try std.testing.expect(s.dst == .west);
        },
        else => return error.TestFailed,
    }
}

test "DisplaySelector.parse" {
    try std.testing.expect(DisplaySelector.parse("focused") == .focused);
    try std.testing.expect(DisplaySelector.parse("next") == .next);
    try std.testing.expect(DisplaySelector.parse("prev") == .prev);
    try std.testing.expect(DisplaySelector.parse("north") == .north);
    try std.testing.expect(DisplaySelector.parse("east") == .east);

    const id_sel = DisplaySelector.parse("2");
    switch (id_sel) {
        .id => |id| try std.testing.expectEqual(@as(Display.Id, 2), id),
        else => return error.TestFailed,
    }

    const label_sel = DisplaySelector.parse("external");
    switch (label_sel) {
        .label => |label| try std.testing.expectEqualStrings("external", label),
        else => return error.TestFailed,
    }
}

test "WindowToggle.parse" {
    try std.testing.expect(WindowToggle.parse("float").? == .float);
    try std.testing.expect(WindowToggle.parse("sticky").? == .sticky);
    try std.testing.expect(WindowToggle.parse("zoom-fullscreen").? == .zoom_fullscreen);
    try std.testing.expect(WindowToggle.parse("native-fullscreen").? == .native_fullscreen);
    try std.testing.expect(WindowToggle.parse("invalid") == null);
}
