const std = @import("std");

/// Known SA function patterns that need to be located in Dock.app
pub const FunctionType = enum {
    dock_spaces, // Global dock spaces object pointer
    dppm, // DPDesktopPictureManager pointer
    add_space, // Function to add a space
    remove_space, // Function to remove a space
    move_space, // Function to move a space
    set_front_window, // Function to focus a window
    fix_animation, // Animation timing patch location

    pub fn name(self: FunctionType) []const u8 {
        return switch (self) {
            .dock_spaces => "dock_spaces",
            .dppm => "dppm",
            .add_space => "add_space",
            .remove_space => "remove_space",
            .move_space => "move_space",
            .set_front_window => "set_front_window",
            .fix_animation => "fix_animation",
        };
    }
};

/// A single pattern definition
pub const Pattern = struct {
    offset: u64, // Offset from base address to start searching
    pattern: []const u8, // Hex pattern with ?? for wildcards
};

/// OS version identifier
pub const OSVersion = struct {
    major: u32,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn format(self: OSVersion, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}.{}.{}", .{ self.major, self.minor, self.patch });
    }
};

/// Architecture
pub const Arch = enum {
    arm64,
    x86_64,

    pub fn current() Arch {
        return switch (@import("builtin").cpu.arch) {
            .aarch64 => .arm64,
            .x86_64 => .x86_64,
            else => @compileError("Unsupported architecture"),
        };
    }
};

/// Complete pattern set for a specific OS version and architecture
pub const PatternSet = struct {
    os: OSVersion,
    arch: Arch,
    dock_spaces: Pattern,
    dppm: Pattern,
    add_space: Pattern,
    remove_space: Pattern,
    move_space: Pattern,
    set_front_window: Pattern,
    fix_animation: Pattern,

    pub fn getPattern(self: *const PatternSet, func: FunctionType) Pattern {
        return switch (func) {
            .dock_spaces => self.dock_spaces,
            .dppm => self.dppm,
            .add_space => self.add_space,
            .remove_space => self.remove_space,
            .move_space => self.move_space,
            .set_front_window => self.set_front_window,
            .fix_animation => self.fix_animation,
        };
    }
};

/// Result of pattern extraction/matching
pub const MatchResult = struct {
    func: FunctionType,
    found: bool,
    address: u64 = 0,
    offset_from_base: u64 = 0,
};

// ============================================================================
// Known byte patterns for SkyLight function discovery
// ============================================================================

pub const known_arm64 = struct {
    // macOS 15 (Sequoia)
    pub const sequoia = PatternSet{
        .os = .{ .major = 15 },
        .arch = .arm64,
        .dock_spaces = .{
            .offset = 0x200000,
            .pattern = "?? 12 00 ?? ?? ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? ?? ?? ??",
        },
        .dppm = .{
            .offset = 0x250000,
            .pattern = "?? 0F 00 ?? ?? ?? ?? 91 ?? 0E 00 ?? ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??",
        },
        .add_space = .{
            .offset = 0x250000,
            .pattern = "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03",
        },
        .remove_space = .{
            .offset = 0x1c0000,
            .pattern = "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? AA",
        },
        .move_space = .{
            .offset = 0x1c0000,
            .pattern = "7F 23 03 D5 E3 03 1E AA ?? ?? FF 97 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FB 03 01 AA FA 03 00 AA ?? 13 00 ?? E8 ?? ?? F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA",
        },
        .set_front_window = .{
            .offset = 0x35000,
            .pattern = "7F 23 03 D5 FF ?? 02 D1 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD ?? 02 91 ?? ?? 00 ?? 08 ?? ?? F9",
        },
        .fix_animation = .{
            .offset = 0x250000,
            .pattern = "00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8",
        },
    };

    // macOS 15.4+ (Sequoia with updated offsets)
    pub const sequoia_15_4 = PatternSet{
        .os = .{ .major = 15, .minor = 4 },
        .arch = .arm64,
        .dock_spaces = .{
            .offset = 0x1f0000, // Updated for 15.4+
            .pattern = "?? 12 00 ?? ?? ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? ?? ?? ??",
        },
        .dppm = .{
            .offset = 0x250000,
            .pattern = "?? 0F 00 ?? ?? ?? ?? 91 ?? 0E 00 ?? ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??",
        },
        .add_space = .{
            .offset = 0x250000,
            .pattern = "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03",
        },
        .remove_space = .{
            .offset = 0x1c0000,
            .pattern = "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? AA",
        },
        .move_space = .{
            .offset = 0x1c0000,
            .pattern = "7F 23 03 D5 E3 03 1E AA ?? ?? FF 97 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FB 03 01 AA FA 03 00 AA ?? 13 00 ?? E8 ?? ?? F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA",
        },
        .set_front_window = .{
            .offset = 0x35000,
            .pattern = "7F 23 03 D5 FF ?? 02 D1 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD ?? 02 91 ?? ?? 00 ?? 08 ?? ?? F9",
        },
        .fix_animation = .{
            .offset = 0x250000,
            .pattern = "00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8",
        },
    };

    // macOS 14 (Sonoma)
    pub const sonoma = PatternSet{
        .os = .{ .major = 14 },
        .arch = .arm64,
        .dock_spaces = .{
            .offset = 0x114000,
            .pattern = "36 16 00 ?? D6 ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? 03 14 AA",
        },
        .dppm = .{
            .offset = 0x1d2000,
            .pattern = "?? 10 00 ?? ?? ?? ?? 91 ?? 0F 00 D0 ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??",
        },
        .add_space = .{
            .offset = 0x1D0000,
            .pattern = "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F5 03",
        },
        .remove_space = .{
            .offset = 0x280000,
            .pattern = "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? 97 FC 03 00 AA 08 FC 7E D3 ?? ?? 00 B5 88 E3 7D 92 00",
        },
        .move_space = .{
            .offset = 0x280000,
            .pattern = "7F 23 03 D5 FF C3 01 D1 E3 03 1E AA ?? ?? 00 94 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FA 03 01 AA FB 03 00 AA ?? ?? 00 ?? F7 ?? ?? 91 E8 02 40 F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA ?? 25 00 94 ?? ?? 00 B4 ?? 03 00 AA ?? 03 01 AA",
        },
        .set_front_window = .{
            .offset = 0x42000,
            .pattern = "7F 23 03 D5 FF ?? 02 D1 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD ?? 02 91 ?? ?? 00 ?? 08 ?? ?? F9 08 01 40 F9 A8 83 1D F8 ?? ?? 00 ?? ?? ?? ?? ?? ?? 03 ?? AA ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? ?? 00 ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? E8 ?? 06 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ??",
        },
        .fix_animation = .{
            .offset = 0x1D0000,
            .pattern = "00 10 6A 1E E0 03 14 AA ?? 03 ?? AA",
        },
    };

    // macOS 26 (Tahoe preview)
    pub const tahoe = PatternSet{
        .os = .{ .major = 26 },
        .arch = .arm64,
        .dock_spaces = .{
            .offset = 0x30000,
            .pattern = "?8 ?? ?? ?? 08 ?? ?? 91 00 01 40 F9 E2 03 13 AA ?? ?? ?? 94 ?? ?? ?? ?? 08",
        },
        .dppm = .{
            .offset = 0x70000,
            .pattern = "?? 20 00 ?? 08 ?? ?? 91 00 01 40 F9 E2 03 16 AA E3 03 19 AA ?? ?? ?? 94",
        },
        .add_space = .{
            .offset = 0x250000,
            .pattern = "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03",
        },
        .remove_space = .{
            .offset = 0x1e0000,
            .pattern = "7F 23 03 D5 FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? ?? A9 F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA F4 03 01 AA",
        },
        .move_space = .{
            .offset = 0x1c0000,
            .pattern = "7F 23 03 D5 E3 03 1E AA ?? ?? ?? 97 FE 03 03 AA FD 7B ?? A9 FD ?? ?? 91 F6 03 14 AA",
        },
        .set_front_window = .{
            .offset = 0x10000,
            .pattern = "21 ?? ?? 34 7F 23 03 D5 FF ?? 01 D1 F6 ?? 04 A9 F4 ?? 05 A9 FD ?? 06 A9 FD ?? 01 91",
        },
        .fix_animation = .{
            .offset = 0x250000,
            .pattern = "00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8",
        },
    };
};

/// Get the best matching pattern set for the current OS
pub fn getPatternSet(os: OSVersion, arch: Arch) ?*const PatternSet {
    if (arch != .arm64) {
        // TODO: Add x86_64 patterns
        return null;
    }

    // Match by major version, with special cases for minor versions
    if (os.major == 26) {
        return &known_arm64.tahoe;
    } else if (os.major == 15) {
        if (os.minor >= 4) {
            return &known_arm64.sequoia_15_4;
        }
        return &known_arm64.sequoia;
    } else if (os.major == 14) {
        return &known_arm64.sonoma;
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "pattern set selection" {
    const testing = std.testing;

    // Sequoia 15.0
    const seq = getPatternSet(.{ .major = 15, .minor = 0 }, .arm64);
    try testing.expect(seq != null);
    try testing.expectEqual(@as(u64, 0x200000), seq.?.dock_spaces.offset);

    // Sequoia 15.4+
    const seq4 = getPatternSet(.{ .major = 15, .minor = 4 }, .arm64);
    try testing.expect(seq4 != null);
    try testing.expectEqual(@as(u64, 0x1f0000), seq4.?.dock_spaces.offset);

    // Sonoma 14
    const son = getPatternSet(.{ .major = 14 }, .arm64);
    try testing.expect(son != null);
    try testing.expectEqual(@as(u64, 0x114000), son.?.dock_spaces.offset);

    // Tahoe 26
    const tah = getPatternSet(.{ .major = 26 }, .arm64);
    try testing.expect(tah != null);
    try testing.expectEqual(@as(u64, 0x30000), tah.?.dock_spaces.offset);

    // Unknown version
    const unk = getPatternSet(.{ .major = 13 }, .arm64);
    try testing.expect(unk == null);
}
