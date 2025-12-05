//! Configuration state for yabai.zig tiling window system.
//! Handles parsing and storing all config settings.
//!
//! Config file format (example):
//! ```
//! # Global defaults
//! layout bsp
//! window_gap 10
//! padding 10 10 10 10
//! split_ratio 0.5
//!
//! # Display configuration - label displays by type
//! display builtin laptop
//! display external main
//!
//! # Named spaces with display assignments
//! space code display=main
//! space chat display=laptop
//! space media display=main layout=stack
//!
//! # App rules - assign to spaces, set properties
//! rule app="Code" space=code
//! rule app="Slack" space=chat
//! rule app="Spotify" space=media manage=off
//! rule app="^System" manage=off   # regex match
//! rule title="Picture in Picture" sticky=on layer=above
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const View = @import("../core/View.zig");

const Config = @This();

// Layout defaults
layout: View.Layout = .bsp,
split_ratio: f32 = 0.5,
split_type: View.Split = .none, // .none means auto-detect based on area ratio
auto_balance: bool = false,

// Padding & gaps (defaults)
top_padding: u32 = 0,
bottom_padding: u32 = 0,
left_padding: u32 = 0,
right_padding: u32 = 0,
window_gap: u32 = 0,

// Window placement
window_placement: WindowPlacement = .second,
window_insertion_point: InsertionPoint = .focused,
window_zoom_persist: bool = false,

// Window origin for new windows
window_origin: WindowOrigin = .default,

// Focus behavior
focus_follows_mouse: FocusFollowsMouse = .disabled,
mouse_follows_focus: bool = false,

// Opacity settings
window_opacity: bool = false,
window_opacity_duration: f32 = 0.0,
active_window_opacity: f32 = 1.0,
normal_window_opacity: f32 = 0.9,

// Animation settings
window_animation_duration: f32 = 0.0,
window_animation_easing: AnimationEasing = .ease_out_circ,

// Menubar
menubar_opacity: f32 = 1.0,

// Mouse settings
mouse_modifier: MouseModifier = .fn_key,
mouse_action1: MouseAction = .move,
mouse_action2: MouseAction = .resize,
mouse_drop_action: MouseDropAction = .swap,

// Visual feedback
insert_feedback_color: u32 = 0xffd75f5f,

// Misc
purify_mode: PurifyMode = .disabled,
external_bar: ExternalBar = .{},

// Dynamic config (requires allocator)
allocator: ?Allocator = null,
displays: std.ArrayList(DisplayConfig) = .{},
spaces: std.ArrayList(SpaceConfig) = .{},
rules: std.ArrayList(AppRule) = .{},

pub const WindowPlacement = enum { first, second };
pub const InsertionPoint = enum { focused, first, last };
pub const WindowOrigin = enum { default, focused, cursor };
pub const FocusFollowsMouse = enum { disabled, autofocus, autoraise };
pub const AnimationEasing = enum { ease_in_sine, ease_out_sine, ease_in_out_sine, ease_in_quad, ease_out_quad, ease_in_out_quad, ease_in_cubic, ease_out_cubic, ease_in_out_cubic, ease_in_quart, ease_out_quart, ease_in_out_quart, ease_in_quint, ease_out_quint, ease_in_out_quint, ease_in_expo, ease_out_expo, ease_in_out_expo, ease_in_circ, ease_out_circ, ease_in_out_circ };
pub const MouseModifier = enum { fn_key, shift, ctrl, alt, cmd };
pub const MouseAction = enum { move, resize };
pub const MouseDropAction = enum { swap, stack };
pub const PurifyMode = enum { disabled, on, off };

pub const ExternalBar = struct {
    position: Position = .off,
    top_padding: u32 = 0,
    bottom_padding: u32 = 0,

    pub const Position = enum { off, main, all };
};

// ============================================================================
// Named Spaces
// ============================================================================

/// A named space with optional layout overrides
pub const SpaceConfig = struct {
    name: []const u8,
    display: ?[]const u8 = null, // display label this space belongs to
    layout: ?View.Layout = null,
    split_ratio: ?f32 = null,
    split_type: ?View.Split = null,
    window_gap: ?u32 = null,
    padding: ?Padding = null,
    auto_balance: ?bool = null,

    pub const Padding = struct {
        top: u32,
        bottom: u32,
        left: u32,
        right: u32,
    };
};

// ============================================================================
// Display Configuration
// ============================================================================

/// How to match a physical display
pub const DisplayMatch = union(enum) {
    builtin, // laptop's built-in display
    external, // any external display (first found if multiple)
    // Future: largest, smallest, left, right, resolution, etc.
};

/// A display configuration - matches physical displays to labels
pub const DisplayConfig = struct {
    match: DisplayMatch,
    label: []const u8,
    layout: ?View.Layout = null, // default layout for spaces on this display
};

// ============================================================================
// App Rules
// ============================================================================

/// A rule for matching and configuring windows
pub const AppRule = struct {
    // Matching criteria (null = don't match on this)
    app: ?[]const u8 = null, // app name or regex
    title: ?[]const u8 = null, // window title or regex
    app_regex: bool = false, // true if app is a regex
    title_regex: bool = false, // true if title is a regex

    // Actions
    space: ?[]const u8 = null, // move to named space
    display: ?u8 = null, // move to display (1-based)
    manage: ?bool = null, // whether to tile this window
    sticky: ?bool = null, // show on all spaces
    layer: ?Layer = null, // window layer
    opacity: ?f32 = null, // window opacity
    fullscreen: ?bool = null, // native fullscreen

    pub const Layer = enum { below, normal, above };
};

// ============================================================================
// Config with profiles and rules
// ============================================================================

/// Parse a config key and set its value
pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "layout")) {
        self.layout = std.meta.stringToEnum(View.Layout, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "split_ratio")) {
        self.split_ratio = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "split_type")) {
        self.split_type = std.meta.stringToEnum(View.Split, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "auto_balance")) {
        self.auto_balance = parseBool(value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "top_padding")) {
        self.top_padding = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "bottom_padding")) {
        self.bottom_padding = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "left_padding")) {
        self.left_padding = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "right_padding")) {
        self.right_padding = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_gap")) {
        self.window_gap = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_placement")) {
        self.window_placement = std.meta.stringToEnum(WindowPlacement, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_insertion_point")) {
        self.window_insertion_point = std.meta.stringToEnum(InsertionPoint, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_zoom_persist")) {
        self.window_zoom_persist = parseBool(value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_origin")) {
        self.window_origin = std.meta.stringToEnum(WindowOrigin, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "focus_follows_mouse")) {
        self.focus_follows_mouse = std.meta.stringToEnum(FocusFollowsMouse, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "mouse_follows_focus")) {
        self.mouse_follows_focus = parseBool(value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_opacity")) {
        self.window_opacity = parseBool(value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_opacity_duration")) {
        self.window_opacity_duration = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "active_window_opacity")) {
        self.active_window_opacity = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "normal_window_opacity")) {
        self.normal_window_opacity = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_animation_duration")) {
        self.window_animation_duration = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "window_animation_easing")) {
        self.window_animation_easing = std.meta.stringToEnum(AnimationEasing, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "menubar_opacity")) {
        self.menubar_opacity = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "mouse_modifier")) {
        self.mouse_modifier = std.meta.stringToEnum(MouseModifier, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "mouse_action1")) {
        self.mouse_action1 = std.meta.stringToEnum(MouseAction, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "mouse_action2")) {
        self.mouse_action2 = std.meta.stringToEnum(MouseAction, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "mouse_drop_action")) {
        self.mouse_drop_action = std.meta.stringToEnum(MouseDropAction, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "insert_feedback_color")) {
        self.insert_feedback_color = parseHexColor(value) orelse return error.InvalidValue;
    } else {
        return error.UnknownKey;
    }
}

/// Get a config value as a string
pub fn get(self: *const Config, key: []const u8, buf: []u8) ![]const u8 {
    if (std.mem.eql(u8, key, "layout")) {
        return @tagName(self.layout);
    } else if (std.mem.eql(u8, key, "split_ratio")) {
        return std.fmt.bufPrint(buf, "{d:.4}", .{self.split_ratio}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "split_type")) {
        return @tagName(self.split_type);
    } else if (std.mem.eql(u8, key, "auto_balance")) {
        return if (self.auto_balance) "on" else "off";
    } else if (std.mem.eql(u8, key, "top_padding")) {
        return std.fmt.bufPrint(buf, "{d}", .{self.top_padding}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "bottom_padding")) {
        return std.fmt.bufPrint(buf, "{d}", .{self.bottom_padding}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "left_padding")) {
        return std.fmt.bufPrint(buf, "{d}", .{self.left_padding}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "right_padding")) {
        return std.fmt.bufPrint(buf, "{d}", .{self.right_padding}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "window_gap")) {
        return std.fmt.bufPrint(buf, "{d}", .{self.window_gap}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "window_placement")) {
        return @tagName(self.window_placement);
    } else if (std.mem.eql(u8, key, "window_origin")) {
        return @tagName(self.window_origin);
    } else if (std.mem.eql(u8, key, "focus_follows_mouse")) {
        return @tagName(self.focus_follows_mouse);
    } else if (std.mem.eql(u8, key, "mouse_follows_focus")) {
        return if (self.mouse_follows_focus) "on" else "off";
    } else if (std.mem.eql(u8, key, "window_opacity")) {
        return if (self.window_opacity) "on" else "off";
    } else if (std.mem.eql(u8, key, "active_window_opacity")) {
        return std.fmt.bufPrint(buf, "{d:.4}", .{self.active_window_opacity}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "normal_window_opacity")) {
        return std.fmt.bufPrint(buf, "{d:.4}", .{self.normal_window_opacity}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "window_animation_duration")) {
        return std.fmt.bufPrint(buf, "{d:.4}", .{self.window_animation_duration}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "menubar_opacity")) {
        return std.fmt.bufPrint(buf, "{d:.4}", .{self.menubar_opacity}) catch return error.BufferTooSmall;
    } else if (std.mem.eql(u8, key, "insert_feedback_color")) {
        return std.fmt.bufPrint(buf, "0x{x:0>8}", .{self.insert_feedback_color}) catch return error.BufferTooSmall;
    } else {
        return error.UnknownKey;
    }
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
        return true;
    } else if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
        return false;
    }
    return null;
}

fn parseHexColor(value: []const u8) ?u32 {
    var s = value;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s = s[2..];
    }
    return std.fmt.parseInt(u32, s, 16) catch null;
}

// ============================================================================
// Space, Profile, and Rule management
// ============================================================================

/// Initialize config with allocator for dynamic data
pub fn initWithAllocator(allocator: Allocator) Config {
    return .{ .allocator = allocator };
}

/// Cleanup dynamic allocations
pub fn deinit(self: *Config) void {
    const alloc = self.allocator orelse return;

    // Free display labels
    for (self.displays.items) |display| {
        alloc.free(display.label);
    }
    self.displays.deinit(alloc);

    // Free space names and display refs
    for (self.spaces.items) |space| {
        alloc.free(space.name);
        if (space.display) |d| alloc.free(d);
    }
    self.spaces.deinit(alloc);

    // Free rule strings
    for (self.rules.items) |rule| {
        if (rule.app) |app| alloc.free(app);
        if (rule.title) |title| alloc.free(title);
        if (rule.space) |space| alloc.free(space);
    }
    self.rules.deinit(alloc);
}

/// Add a display configuration
pub fn addDisplay(self: *Config, match: DisplayMatch, label: []const u8) !*DisplayConfig {
    const alloc = self.allocator orelse return error.NoAllocator;
    const owned_label = try alloc.dupe(u8, label);
    errdefer alloc.free(owned_label);

    try self.displays.append(alloc, .{ .match = match, .label = owned_label });
    return &self.displays.items[self.displays.items.len - 1];
}

/// Get a display configuration by label
pub fn getDisplay(self: *const Config, label: []const u8) ?*const DisplayConfig {
    for (self.displays.items) |*display| {
        if (std.mem.eql(u8, display.label, label)) return display;
    }
    return null;
}

/// Add a named space configuration
pub fn addSpace(self: *Config, name: []const u8) !*SpaceConfig {
    const alloc = self.allocator orelse return error.NoAllocator;
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);

    try self.spaces.append(alloc, .{ .name = owned_name });
    return &self.spaces.items[self.spaces.items.len - 1];
}

/// Get a space configuration by name
pub fn getSpace(self: *const Config, name: []const u8) ?*const SpaceConfig {
    for (self.spaces.items) |*space| {
        if (std.mem.eql(u8, space.name, name)) return space;
    }
    return null;
}

/// Add an app rule
pub fn addRule(self: *Config, rule: AppRule) !void {
    const alloc = self.allocator orelse return error.NoAllocator;

    // Duplicate strings
    var owned_rule = rule;
    if (rule.app) |app| {
        owned_rule.app = try alloc.dupe(u8, app);
    }
    errdefer if (owned_rule.app) |app| alloc.free(app);

    if (rule.title) |title| {
        owned_rule.title = try alloc.dupe(u8, title);
    }
    errdefer if (owned_rule.title) |title| alloc.free(title);

    if (rule.space) |space| {
        owned_rule.space = try alloc.dupe(u8, space);
    }

    try self.rules.append(alloc, owned_rule);
}

/// Find matching rules for an app/window
pub fn findMatchingRules(
    self: *const Config,
    app_name: []const u8,
    window_title: ?[]const u8,
    allocator: Allocator,
) ![]const *const AppRule {
    var matches = std.ArrayList(*const AppRule){};
    errdefer matches.deinit(allocator);

    for (self.rules.items) |*rule| {
        if (ruleMatches(rule, app_name, window_title)) {
            try matches.append(allocator, rule);
        }
    }

    return matches.toOwnedSlice(allocator);
}

fn ruleMatches(rule: *const AppRule, app_name: []const u8, window_title: ?[]const u8) bool {
    // Check app match (case-insensitive)
    if (rule.app) |pattern| {
        if (rule.app_regex) {
            // TODO: regex matching
            if (!containsIgnoreCase(app_name, pattern)) return false;
        } else {
            if (!eqlIgnoreCase(app_name, pattern)) return false;
        }
    }

    // Check title match
    if (rule.title) |pattern| {
        const title = window_title orelse return false;
        if (rule.title_regex) {
            // TODO: regex matching
            if (!std.mem.containsAtLeast(u8, title, 1, pattern)) return false;
        } else {
            if (!std.mem.eql(u8, title, pattern)) return false;
        }
    }

    return true;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    for (0..haystack.len - needle.len + 1) |i| {
        if (eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// ============================================================================
// Config File Parser
// ============================================================================

pub const ParseError = error{
    UnexpectedToken,
    InvalidValue,
    UnknownKey,
    MissingValue,
    UnterminatedBlock,
    OutOfMemory,
    NoAllocator,
};

/// Parse a config file
pub fn parseFile(self: *Config, path: []const u8) !void {
    const alloc = self.allocator orelse return error.NoAllocator;
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return; // Config file optional
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024); // 1MB max
    defer alloc.free(content);

    try self.parse(content);
}

/// Parse config from string
pub fn parse(self: *Config, content: []const u8) ParseError!void {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (line_iter.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        try self.parseLine(trimmed);
    }
}

fn parseLine(self: *Config, line: []const u8) ParseError!void {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = tokens.next() orelse return;

    if (std.mem.eql(u8, cmd, "display")) {
        try self.parseDisplayDecl(&tokens);
    } else if (std.mem.eql(u8, cmd, "space")) {
        try self.parseSpaceDecl(&tokens);
    } else if (std.mem.eql(u8, cmd, "rule")) {
        try self.parseRuleDecl(&tokens);
    } else if (std.mem.eql(u8, cmd, "padding")) {
        try self.parsePadding(&tokens);
    } else if (std.mem.eql(u8, cmd, "external_bar")) {
        try self.parseExternalBar(&tokens);
    } else {
        // Global key=value or key value
        const value = tokens.next() orelse return error.MissingValue;
        self.set(cmd, value) catch return error.InvalidValue;
    }
}

/// Parse: display builtin laptop
/// Parse: display external main
fn parseDisplayDecl(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    const match_str = tokens.next() orelse return error.MissingValue;
    const label = tokens.next() orelse return error.MissingValue;

    const match: DisplayMatch = if (std.mem.eql(u8, match_str, "builtin"))
        .builtin
    else if (std.mem.eql(u8, match_str, "external"))
        .external
    else
        return error.InvalidValue;

    _ = try self.addDisplay(match, label);
}

fn parseSpaceDecl(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    const alloc = self.allocator orelse return error.NoAllocator;
    const name = tokens.next() orelse return error.MissingValue;

    const space = try self.addSpace(name);

    // Parse optional key=value pairs (e.g., display=laptop)
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "{")) continue; // ignore block syntax for now

        // Parse key=value
        if (std.mem.indexOfScalar(u8, token, '=')) |eq_pos| {
            const key = token[0..eq_pos];
            const value = token[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "display")) {
                space.display = try alloc.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "layout")) {
                space.layout = std.meta.stringToEnum(View.Layout, value);
            }
        }
    }
}

fn parseRuleDecl(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    var rule = AppRule{};

    // Collect remaining line and parse key=value pairs
    // Handle quoted values that may contain spaces
    const rest = tokens.rest();
    var i: usize = 0;

    while (i < rest.len) {
        // Skip whitespace
        while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
        if (i >= rest.len) break;

        // Find key
        const key_start = i;
        while (i < rest.len and rest[i] != '=') : (i += 1) {}
        if (i >= rest.len) break;

        const key = rest[key_start..i];
        i += 1; // skip '='

        // Parse value (handle quotes)
        var value: []const u8 = undefined;
        if (i < rest.len and rest[i] == '"') {
            i += 1; // skip opening quote
            const value_start = i;
            while (i < rest.len and rest[i] != '"') : (i += 1) {}
            value = rest[value_start..i];
            if (i < rest.len) i += 1; // skip closing quote
        } else {
            const value_start = i;
            while (i < rest.len and rest[i] != ' ' and rest[i] != '\t') : (i += 1) {}
            value = rest[value_start..i];
        }

        if (std.mem.eql(u8, key, "app")) {
            if (value.len > 0 and value[0] == '^') {
                rule.app = value;
                rule.app_regex = true;
            } else {
                rule.app = value;
            }
        } else if (std.mem.eql(u8, key, "title")) {
            if (value.len > 0 and value[0] == '^') {
                rule.title = value;
                rule.title_regex = true;
            } else {
                rule.title = value;
            }
        } else if (std.mem.eql(u8, key, "space")) {
            rule.space = value;
        } else if (std.mem.eql(u8, key, "display")) {
            rule.display = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "manage")) {
            rule.manage = parseBool(value);
        } else if (std.mem.eql(u8, key, "sticky")) {
            rule.sticky = parseBool(value);
        } else if (std.mem.eql(u8, key, "layer")) {
            rule.layer = std.meta.stringToEnum(AppRule.Layer, value);
        } else if (std.mem.eql(u8, key, "opacity")) {
            rule.opacity = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "fullscreen")) {
            rule.fullscreen = parseBool(value);
        }
    }

    try self.addRule(rule);
}

fn parsePadding(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    const values = [_]?[]const u8{
        tokens.next(),
        tokens.next(),
        tokens.next(),
        tokens.next(),
    };

    // Support "padding 10" (all), "padding 10 20" (vertical horizontal), or "padding 10 20 30 40" (t r b l)
    if (values[0]) |top| {
        const t = std.fmt.parseInt(u32, top, 10) catch return error.InvalidValue;

        if (values[1]) |right| {
            const r = std.fmt.parseInt(u32, right, 10) catch return error.InvalidValue;

            if (values[2]) |bottom| {
                const b = std.fmt.parseInt(u32, bottom, 10) catch return error.InvalidValue;
                const l = std.fmt.parseInt(u32, values[3] orelse return error.MissingValue, 10) catch return error.InvalidValue;
                self.top_padding = t;
                self.right_padding = r;
                self.bottom_padding = b;
                self.left_padding = l;
            } else {
                // Two values: vertical horizontal
                self.top_padding = t;
                self.bottom_padding = t;
                self.left_padding = r;
                self.right_padding = r;
            }
        } else {
            // Single value: all
            self.top_padding = t;
            self.bottom_padding = t;
            self.left_padding = t;
            self.right_padding = t;
        }
    }
}

/// Parse external_bar setting: external_bar <position>:<top>:<bottom>
/// Example: external_bar all:36:0
fn parseExternalBar(self: *Config, tokens: *std.mem.TokenIterator(u8, .any)) ParseError!void {
    const spec = tokens.next() orelse return error.MissingValue;

    // Parse "position:top:bottom" format
    var parts = std.mem.splitScalar(u8, spec, ':');

    const position_str = parts.next() orelse return error.InvalidValue;
    const top_str = parts.next() orelse return error.InvalidValue;
    const bottom_str = parts.next() orelse return error.InvalidValue;

    self.external_bar.position = std.meta.stringToEnum(ExternalBar.Position, position_str) orelse return error.InvalidValue;
    self.external_bar.top_padding = std.fmt.parseInt(u32, top_str, 10) catch return error.InvalidValue;
    self.external_bar.bottom_padding = std.fmt.parseInt(u32, bottom_str, 10) catch return error.InvalidValue;
}

// Tests
test "set and get layout" {
    var config = Config{};
    try config.set("layout", "float");
    try std.testing.expectEqual(View.Layout.float, config.layout);

    var buf: [64]u8 = undefined;
    const result = try config.get("layout", &buf);
    try std.testing.expectEqualStrings("float", result);
}

test "set and get numeric values" {
    var config = Config{};
    try config.set("top_padding", "20");
    try std.testing.expectEqual(@as(u32, 20), config.top_padding);

    try config.set("split_ratio", "0.65");
    try std.testing.expect(@abs(config.split_ratio - 0.65) < 0.001);
}

test "set and get boolean values" {
    var config = Config{};
    try config.set("auto_balance", "on");
    try std.testing.expect(config.auto_balance);

    try config.set("auto_balance", "off");
    try std.testing.expect(!config.auto_balance);
}

test "parse hex color" {
    try std.testing.expectEqual(@as(?u32, 0xff0000), parseHexColor("0xff0000"));
    try std.testing.expectEqual(@as(?u32, 0xaabbcc), parseHexColor("aabbcc"));
    try std.testing.expectEqual(@as(?u32, 0xffd75f5f), parseHexColor("0xffd75f5f"));
}

test "invalid key returns error" {
    var config = Config{};
    try std.testing.expectError(error.UnknownKey, config.set("nonexistent_key", "value"));
}

test "invalid value returns error" {
    var config = Config{};
    try std.testing.expectError(error.InvalidValue, config.set("top_padding", "not_a_number"));
    try std.testing.expectError(error.InvalidValue, config.set("layout", "invalid_layout"));
}

test "space configuration" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    const space = try config.addSpace("code");
    space.layout = .bsp;
    space.window_gap = 10;

    const found = config.getSpace("code");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(View.Layout.bsp, found.?.layout.?);
    try std.testing.expectEqual(@as(u32, 10), found.?.window_gap.?);

    try std.testing.expect(config.getSpace("nonexistent") == null);
}

test "app rule matching" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.addRule(.{ .app = "Code", .space = "code" });
    try config.addRule(.{ .app = "Slack", .space = "chat", .manage = true });
    try config.addRule(.{ .title = "Picture in Picture", .sticky = true, .layer = .above });

    const code_rules = try config.findMatchingRules("Code", null, std.testing.allocator);
    defer std.testing.allocator.free(code_rules);
    try std.testing.expectEqual(@as(usize, 1), code_rules.len);
    try std.testing.expectEqualStrings("code", code_rules[0].space.?);

    const pip_rules = try config.findMatchingRules("Safari", "Picture in Picture", std.testing.allocator);
    defer std.testing.allocator.free(pip_rules);
    try std.testing.expectEqual(@as(usize, 1), pip_rules.len);
    try std.testing.expect(pip_rules[0].sticky.?);
}

test "parse global config" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.parse(
        \\# Comment
        \\layout bsp
        \\window_gap 10
        \\split_ratio 0.6
        \\padding 20
    );

    try std.testing.expectEqual(View.Layout.bsp, config.layout);
    try std.testing.expectEqual(@as(u32, 10), config.window_gap);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), config.split_ratio, 0.001);
    try std.testing.expectEqual(@as(u32, 20), config.top_padding);
    try std.testing.expectEqual(@as(u32, 20), config.left_padding);
}

test "parse padding variations" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    // Single value
    try config.parse("padding 10");
    try std.testing.expectEqual(@as(u32, 10), config.top_padding);
    try std.testing.expectEqual(@as(u32, 10), config.right_padding);

    // Two values (vertical horizontal)
    try config.parse("padding 5 15");
    try std.testing.expectEqual(@as(u32, 5), config.top_padding);
    try std.testing.expectEqual(@as(u32, 5), config.bottom_padding);
    try std.testing.expectEqual(@as(u32, 15), config.left_padding);
    try std.testing.expectEqual(@as(u32, 15), config.right_padding);

    // Four values (t r b l)
    try config.parse("padding 1 2 3 4");
    try std.testing.expectEqual(@as(u32, 1), config.top_padding);
    try std.testing.expectEqual(@as(u32, 2), config.right_padding);
    try std.testing.expectEqual(@as(u32, 3), config.bottom_padding);
    try std.testing.expectEqual(@as(u32, 4), config.left_padding);
}

test "parse rules" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.parse(
        \\rule app=Code space=code
        \\rule app=Slack space=chat manage=on
        \\rule title="Picture in Picture" sticky=on layer=above
    );

    try std.testing.expectEqual(@as(usize, 3), config.rules.items.len);

    const r1 = config.rules.items[0];
    try std.testing.expectEqualStrings("Code", r1.app.?);
    try std.testing.expectEqualStrings("code", r1.space.?);

    const r2 = config.rules.items[1];
    try std.testing.expect(r2.manage.?);

    const r3 = config.rules.items[2];
    try std.testing.expectEqualStrings("Picture in Picture", r3.title.?);
    try std.testing.expect(r3.sticky.?);
    try std.testing.expectEqual(AppRule.Layer.above, r3.layer.?);
}

test "parse spaces" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.parse(
        \\space code
        \\space chat
        \\space media
    );

    try std.testing.expectEqual(@as(usize, 3), config.spaces.items.len);
    try std.testing.expect(config.getSpace("code") != null);
    try std.testing.expect(config.getSpace("chat") != null);
    try std.testing.expect(config.getSpace("media") != null);
}

test "parse external_bar" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.parse("external_bar all:36:0");
    try std.testing.expectEqual(ExternalBar.Position.all, config.external_bar.position);
    try std.testing.expectEqual(@as(u32, 36), config.external_bar.top_padding);
    try std.testing.expectEqual(@as(u32, 0), config.external_bar.bottom_padding);

    try config.parse("external_bar main:40:10");
    try std.testing.expectEqual(ExternalBar.Position.main, config.external_bar.position);
    try std.testing.expectEqual(@as(u32, 40), config.external_bar.top_padding);
    try std.testing.expectEqual(@as(u32, 10), config.external_bar.bottom_padding);
}

test "case insensitive app matching" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.addRule(.{ .app = "Slack", .space = "chat" });

    // Should match regardless of case
    const rules1 = try config.findMatchingRules("Slack", null, std.testing.allocator);
    defer std.testing.allocator.free(rules1);
    try std.testing.expectEqual(@as(usize, 1), rules1.len);

    const rules2 = try config.findMatchingRules("slack", null, std.testing.allocator);
    defer std.testing.allocator.free(rules2);
    try std.testing.expectEqual(@as(usize, 1), rules2.len);

    const rules3 = try config.findMatchingRules("SLACK", null, std.testing.allocator);
    defer std.testing.allocator.free(rules3);
    try std.testing.expectEqual(@as(usize, 1), rules3.len);
}

test "regex pattern matching (contains)" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    // Note: regex is currently implemented as case-insensitive contains
    try config.addRule(.{ .app = "System", .app_regex = true, .manage = false });

    // Should match apps containing "System"
    const rules1 = try config.findMatchingRules("System Preferences", null, std.testing.allocator);
    defer std.testing.allocator.free(rules1);
    try std.testing.expectEqual(@as(usize, 1), rules1.len);

    const rules2 = try config.findMatchingRules("System Settings", null, std.testing.allocator);
    defer std.testing.allocator.free(rules2);
    try std.testing.expectEqual(@as(usize, 1), rules2.len);

    // Should not match
    const rules3 = try config.findMatchingRules("Code", null, std.testing.allocator);
    defer std.testing.allocator.free(rules3);
    try std.testing.expectEqual(@as(usize, 0), rules3.len);
}

test "empty config" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.parse("");
    try config.parse("   \n\n   ");
    try config.parse("# just comments\n# more comments");

    // Should have defaults
    try std.testing.expectEqual(View.Layout.bsp, config.layout);
    try std.testing.expectEqual(@as(u32, 0), config.window_gap);
}

test "rule with quoted app name" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.parse(
        \\rule app="Visual Studio Code" space=code
    );

    try std.testing.expectEqual(@as(usize, 1), config.rules.items.len);
    try std.testing.expectEqualStrings("Visual Studio Code", config.rules.items[0].app.?);
}

test "multiple rules for same app" {
    var config = Config.initWithAllocator(std.testing.allocator);
    defer config.deinit();

    try config.addRule(.{ .app = "Code", .space = "code" });
    try config.addRule(.{ .app = "Code", .opacity = 0.9 });

    const rules = try config.findMatchingRules("Code", null, std.testing.allocator);
    defer std.testing.allocator.free(rules);
    try std.testing.expectEqual(@as(usize, 2), rules.len);
}

test "eqlIgnoreCase" {
    try std.testing.expect(eqlIgnoreCase("Hello", "hello"));
    try std.testing.expect(eqlIgnoreCase("HELLO", "hello"));
    try std.testing.expect(eqlIgnoreCase("HeLLo", "hElLO"));
    try std.testing.expect(!eqlIgnoreCase("Hello", "World"));
    try std.testing.expect(!eqlIgnoreCase("Hello", "Hell"));
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Hello World", "world"));
    try std.testing.expect(containsIgnoreCase("Hello World", "HELLO"));
    try std.testing.expect(containsIgnoreCase("System Preferences", "system"));
    try std.testing.expect(!containsIgnoreCase("Hello", "World"));
    try std.testing.expect(containsIgnoreCase("test", ""));
}
