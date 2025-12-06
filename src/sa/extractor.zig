const std = @import("std");
const patterns = @import("patterns.zig");
const objc_analyzer = @import("objc_analyzer.zig");

// FAT binary header (universal binary)
const FatHeader = extern struct {
    magic: u32,
    nfat_arch: u32,
};

const FatArch = extern struct {
    cputype: i32,
    cpusubtype: i32,
    offset: u32,
    size: u32,
    @"align": u32,
};

const FAT_MAGIC: u32 = 0xcafebabe;
const FAT_CIGAM: u32 = 0xbebafeca; // Byte-swapped
const CPU_TYPE_ARM64: i32 = 0x0100000C; // CPU_TYPE_ARM | CPU_ARCH_ABI64

fn swap32(val: u32) u32 {
    return @byteSwap(val);
}

fn swapI32(val: i32) i32 {
    const u: u32 = @bitCast(val);
    return @bitCast(@byteSwap(u));
}

/// Extract the arm64 slice from a FAT binary, or return the original data if not FAT
pub fn extractArm64Slice(data: []const u8) ?[]const u8 {
    if (data.len < @sizeOf(FatHeader)) return data;

    const header: *const FatHeader = @ptrCast(@alignCast(data.ptr));

    const is_fat = header.magic == FAT_MAGIC or header.magic == FAT_CIGAM;
    if (!is_fat) return data; // Not a FAT binary, use as-is

    const needs_swap = header.magic == FAT_CIGAM;
    const nfat_arch = if (needs_swap) swap32(header.nfat_arch) else header.nfat_arch;

    // Parse arch entries
    const arch_ptr: [*]const FatArch = @ptrCast(@alignCast(data.ptr + @sizeOf(FatHeader)));

    for (0..nfat_arch) |i| {
        const arch = arch_ptr[i];
        const cputype = if (needs_swap) swapI32(arch.cputype) else arch.cputype;
        const offset = if (needs_swap) swap32(arch.offset) else arch.offset;
        const size = if (needs_swap) swap32(arch.size) else arch.size;

        // Check for arm64 (includes arm64e)
        if (cputype == CPU_TYPE_ARM64) {
            if (offset + size <= data.len) {
                return data[offset..][0..size];
            }
        }
    }

    return null; // No arm64 slice found
}

/// Parsed hex pattern with mask for wildcards
pub const CompiledPattern = struct {
    bytes: []const u8, // Expected byte values
    mask: []const u8, // 0 = wildcard, 1 = must match
    len: usize,

    pub fn deinit(self: *CompiledPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.mask);
    }
};

/// Parse a hex pattern string like "7F 23 03 D5 ?? ?? 00 94"
/// Returns compiled pattern with bytes and mask arrays
pub fn compilePattern(allocator: std.mem.Allocator, pattern_str: []const u8) !CompiledPattern {
    // Count bytes (pattern is "XX " or "?? " format, 3 chars per byte)
    const byte_count = (pattern_str.len + 1) / 3;
    if (byte_count == 0) return error.EmptyPattern;

    var bytes = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(bytes);
    var mask = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(mask);

    var i: usize = 0;
    var byte_idx: usize = 0;

    while (i < pattern_str.len and byte_idx < byte_count) {
        // Skip spaces
        while (i < pattern_str.len and pattern_str[i] == ' ') : (i += 1) {}
        if (i >= pattern_str.len) break;

        // Check for wildcard
        if (pattern_str[i] == '?') {
            bytes[byte_idx] = 0;
            mask[byte_idx] = 0; // Don't match this byte
            i += 2; // Skip "??"
        } else {
            // Parse hex byte
            const high = hexDigit(pattern_str[i]) orelse return error.InvalidHex;
            const low = if (i + 1 < pattern_str.len) hexDigit(pattern_str[i + 1]) orelse return error.InvalidHex else return error.InvalidHex;
            bytes[byte_idx] = (high << 4) | low;
            mask[byte_idx] = 1; // Must match
            i += 2;
        }

        byte_idx += 1;
        // Skip trailing space
        if (i < pattern_str.len and pattern_str[i] == ' ') i += 1;
    }

    return CompiledPattern{
        .bytes = bytes,
        .mask = mask,
        .len = byte_idx,
    };
}

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'A'...'F' => ch - 'A' + 10,
        'a'...'f' => ch - 'a' + 10,
        else => null,
    };
}

/// Search for a pattern in memory, starting at base_addr + offset
/// Returns the address where pattern was found, or null
pub fn findPattern(data: []const u8, compiled: CompiledPattern, max_search: usize) ?usize {
    if (compiled.len == 0 or data.len < compiled.len) return null;

    const search_limit = @min(max_search, data.len - compiled.len + 1);

    var addr: usize = 0;
    outer: while (addr < search_limit) : (addr += 1) {
        // Try to match pattern at this address
        for (0..compiled.len) |i| {
            if (compiled.mask[i] != 0 and data[addr + i] != compiled.bytes[i]) {
                continue :outer;
            }
        }
        // All bytes matched!
        return addr;
    }

    return null;
}

/// Result of analyzing a Dock binary
pub const AnalysisResult = struct {
    os: patterns.OSVersion,
    arch: patterns.Arch,
    results: [7]patterns.MatchResult,

    pub fn allFound(self: *const AnalysisResult) bool {
        for (self.results) |r| {
            if (!r.found) return false;
        }
        return true;
    }

    pub fn foundCount(self: *const AnalysisResult) usize {
        var count: usize = 0;
        for (self.results) |r| {
            if (r.found) count += 1;
        }
        return count;
    }

    pub fn format(self: AnalysisResult, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("macOS {} ({s})\n", .{ self.os, @tagName(self.arch) });
        try writer.writeAll("─────────────────────────────────────────\n");

        for (self.results) |r| {
            const status = if (r.found) "✓" else "✗";
            const name = r.func.name();
            if (r.found) {
                try writer.print("{s} {s:<20} 0x{x:0>8}\n", .{ status, name, r.offset_from_base });
            } else {
                try writer.print("{s} {s:<20} not found\n", .{ status, name });
            }
        }
    }
};

/// Analyze a Dock binary and try to find all required patterns
pub fn analyzeDock(allocator: std.mem.Allocator, dock_data: []const u8, os: patterns.OSVersion, arch: patterns.Arch) !AnalysisResult {
    const pattern_set = patterns.getPatternSet(os, arch) orelse return error.UnsupportedOS;

    // Extract arm64 slice from FAT binary if needed
    const binary_data = if (arch == .arm64)
        extractArm64Slice(dock_data) orelse return error.NoArm64Slice
    else
        dock_data;

    var result = AnalysisResult{
        .os = os,
        .arch = arch,
        .results = undefined,
    };

    // Try to find each pattern
    inline for (std.meta.fields(patterns.FunctionType), 0..) |field, i| {
        const func: patterns.FunctionType = @enumFromInt(field.value);
        const pattern = pattern_set.getPattern(func);

        var compiled = try compilePattern(allocator, pattern.pattern);
        defer compiled.deinit(allocator);

        // Search from offset with reasonable limit (0x1286a0 matches C code)
        const search_start = @min(pattern.offset, binary_data.len);
        const search_data = binary_data[search_start..];

        if (findPattern(search_data, compiled, 0x1286a0)) |rel_addr| {
            result.results[i] = .{
                .func = func,
                .found = true,
                .address = search_start + rel_addr,
                .offset_from_base = search_start + rel_addr,
            };
        } else {
            result.results[i] = .{
                .func = func,
                .found = false,
            };
        }
    }

    return result;
}

/// Get the current macOS version
pub fn getCurrentOSVersion() !patterns.OSVersion {
    // Read from sw_vers
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "sw_vers", "-productVersion" },
        .max_output_bytes = 256,
    }) catch return error.CannotGetOSVersion;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    // Parse "15.1.2" format
    const version_str = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);

    var parts = std.mem.splitScalar(u8, version_str, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
    const minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    const patch = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;

    return .{ .major = major, .minor = minor, .patch = patch };
}

/// Export analysis results as JSON
pub fn exportJson(allocator: std.mem.Allocator, result: AnalysisResult) ![]u8 {
    // Pre-calculate size and build JSON manually
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.writeAll("{\n");
    try writer.print("  \"os_version\": \"{}.{}.{}\",\n", .{ result.os.major, result.os.minor, result.os.patch });
    try writer.print("  \"arch\": \"{s}\",\n", .{@tagName(result.arch)});
    try writer.writeAll("  \"patterns\": {\n");

    for (result.results, 0..) |r, i| {
        const comma = if (i < result.results.len - 1) "," else "";
        if (r.found) {
            try writer.print("    \"{s}\": {{ \"offset\": \"0x{x:0>8}\", \"found\": true }}{s}\n", .{ r.func.name(), r.offset_from_base, comma });
        } else {
            try writer.print("    \"{s}\": {{ \"found\": false }}{s}\n", .{ r.func.name(), comma });
        }
    }

    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");

    const written = fbs.getWritten();
    const output = try allocator.alloc(u8, written.len);
    @memcpy(output, written);
    return output;
}

/// Selector names used to find each function
const selector_map = [_]struct { func: patterns.FunctionType, selector: []const u8 }{
    .{ .func = .add_space, .selector = "addSpace:forDisplayUUID:" },
    .{ .func = .remove_space, .selector = "removeSpace:" },
    .{ .func = .move_space, .selector = "moveSpace:toDisplay:displayUUID:" },
};

/// Additional selectors to search for global data references
/// These functions reference the globals we need - we analyze their code to find the addresses
const global_reference_selectors = [_]struct {
    target: patterns.FunctionType,
    selector: []const u8,
    description: []const u8,
}{
    .{ .target = .dock_spaces, .selector = "doBindingCommand:display:", .description = "references dock_spaces global" },
    .{ .target = .dppm, .selector = "setDesktopPictureManager", .description = "references dppm global" },
};

/// Discover function addresses by analyzing ObjC selector references
pub fn discoverFunctions(allocator: std.mem.Allocator, binary_data: []const u8) !DiscoveryResult {
    var result = DiscoveryResult{};

    const macho = objc_analyzer.MachOBinary.parse(binary_data) catch |err| {
        result.parse_error = err;
        return result;
    };

    // Step 1: Find direct functions via their selectors
    for (selector_map) |entry| {
        const idx = @intFromEnum(entry.func);
        result.diagnostics[idx].selector_name = entry.selector;

        const maybe_func = macho.findFunctionForSelector(allocator, entry.selector) catch continue;
        if (maybe_func) |func| {
            result.diagnostics[idx].selector_found = true;
            result.diagnostics[idx].method = "ObjC selector";
            result.functions[idx] = .{
                .func = entry.func,
                .found = true,
                .address = func.address,
                .file_offset = func.file_offset,
            };
            @memcpy(result.prologues[idx][0..func.prologue_len], func.prologue[0..func.prologue_len]);
            result.prologue_lens[idx] = func.prologue_len;
        }
    }

    // Step 2: Find global data references via functions that use them
    for (global_reference_selectors) |entry| {
        const idx = @intFromEnum(entry.target);
        result.diagnostics[idx].selector_name = entry.selector;

        const maybe_func = macho.findFunctionForSelector(allocator, entry.selector) catch continue;
        result.diagnostics[idx].selector_found = true;

        if (maybe_func) |func| {
            // Scan this function for ADRP+ADD/LDR sequences that load globals
            const text = macho.text_section orelse continue;
            const func_text_offset = func.file_offset - text.offset;
            const global_refs = macho.findGlobalRefsInFunction(func_text_offset, 200);

            // The first global ref found is likely what we want
            // (This is a heuristic - may need refinement)
            for (global_refs) |maybe_ref| {
                if (maybe_ref) |ref| {
                    if (!result.functions[idx].found) {
                        result.diagnostics[idx].method = "global ref via selector";
                        result.functions[idx] = .{
                            .func = entry.target,
                            .found = true,
                            .address = ref.address,
                            .file_offset = ref.address - 0x100000000, // Convert vmaddr to file offset estimate
                        };
                        break;
                    }
                }
            }
        }
    }

    // Step 3: Pattern-based fallback for remaining functions
    const text = macho.text_section orelse return result;
    const text_data = binary_data[text.offset..][0..@intCast(text.size)];

    // dppm: Look for ADRP+LDR pattern that loads from high __DATA address and then LDR from that pointer
    // Pattern: ADRP Xn, page; LDR Xn, [Xn, #off]; LDR Xm, [Xn] (double dereference)
    const dppm_idx = @intFromEnum(patterns.FunctionType.dppm);
    if (!result.functions[dppm_idx].found) {
        result.diagnostics[dppm_idx].fallback_used = true;
        if (findDppmPattern(text_data, text.addr)) |addr| {
            result.diagnostics[dppm_idx].method = "ADRP+LDR+LDR pattern";
            result.functions[dppm_idx] = .{
                .func = .dppm,
                .found = true,
                .address = addr,
                .file_offset = addr - 0x100000000,
            };
        } else {
            result.diagnostics[dppm_idx].notes = "No ADRP+LDR+LDR to DATA segment found";
        }
    }

    // set_front_window: Find via PACIBSP prologue followed by specific stack frame setup
    const sfw_idx = @intFromEnum(patterns.FunctionType.set_front_window);
    if (!result.functions[sfw_idx].found) {
        result.diagnostics[sfw_idx].fallback_used = true;
        result.diagnostics[sfw_idx].method = "prologue pattern";
        if (findSetFrontWindowPattern(text_data, text.addr, text.offset)) |info| {
            result.functions[sfw_idx] = .{
                .func = .set_front_window,
                .found = true,
                .address = info.address,
                .file_offset = info.file_offset,
            };
            @memcpy(result.prologues[sfw_idx][0..info.prologue_len], info.prologue[0..info.prologue_len]);
            result.prologue_lens[sfw_idx] = info.prologue_len;
        } else {
            result.diagnostics[sfw_idx].notes = "PACIBSP+stack frame pattern not found";
        }
    }

    // fix_animation: Look for FMOV D0, #1.0 (00 10 6A 1E) followed by specific pattern
    const fa_idx = @intFromEnum(patterns.FunctionType.fix_animation);
    if (!result.functions[fa_idx].found) {
        result.diagnostics[fa_idx].fallback_used = true;
        result.diagnostics[fa_idx].method = "FMOV D0 pattern";
        if (findFixAnimationPattern(text_data, text.addr)) |addr| {
            result.functions[fa_idx] = .{
                .func = .fix_animation,
                .found = true,
                .address = addr,
                .file_offset = addr - 0x100000000,
            };
        } else {
            result.diagnostics[fa_idx].notes = "FMOV D0, #1.0 + SUB pattern not found";
        }
    }

    return result;
}

/// Find dppm global pointer via pattern matching
fn findDppmPattern(text_data: []const u8, text_addr: u64) ?u64 {
    // Look for code that loads a global pointer and then dereferences it
    // This is characteristic of accessing a global object pointer like gDesktopPictureManager
    var i: usize = 0;
    while (i + 12 <= text_data.len) : (i += 4) {
        const instr1 = std.mem.readInt(u32, text_data[i..][0..4], .little);
        const instr2 = std.mem.readInt(u32, text_data[i + 4 ..][0..4], .little);
        const instr3 = std.mem.readInt(u32, text_data[i + 8 ..][0..4], .little);

        // ADRP Xn, page
        if ((instr1 & 0x9F000000) != 0x90000000) continue;

        // LDR Xn, [Xn, #imm] (unsigned offset)
        if ((instr2 & 0xFFC00000) != 0xF9400000) continue;

        // LDR Xm, [Xn] or LDR Xm, [Xn, #0] - dereference the pointer
        if ((instr3 & 0xFFC003E0) != 0xF9400000) continue;

        // Decode ADRP to get target address
        const rd1: u5 = @truncate(instr1 & 0x1F);
        const rn2: u5 = @truncate((instr2 >> 5) & 0x1F);
        const rd2: u5 = @truncate(instr2 & 0x1F);
        const rn3: u5 = @truncate((instr3 >> 5) & 0x1F);

        // Verify register chain: ADRP Xn -> LDR Xn, [Xn, ...] -> LDR Xm, [Xn]
        if (rd1 != rn2 or rd2 != rn3) continue;

        const pc = text_addr + i;
        const pc_page = pc & ~@as(u64, 0xFFF);
        const immlo: u64 = (instr1 >> 29) & 0x3;
        const immhi_raw: u32 = (instr1 >> 5) & 0x7FFFF;
        const immhi: i64 = @as(i64, @as(i32, @bitCast(immhi_raw << 13)) >> 13);
        const imm: i64 = (immhi << 14) | @as(i64, @intCast(immlo << 12));
        const target_page: u64 = @intCast(@as(i64, @intCast(pc_page)) +% imm);

        const ldr_imm: u12 = @truncate((instr2 >> 10) & 0xFFF);
        const global_addr = target_page + @as(u64, ldr_imm) * 8;

        // Check if this looks like a __DATA address (0x1003xxxxx or 0x1004xxxxx range)
        if (global_addr >= 0x100300000 and global_addr < 0x100500000) {
            return global_addr;
        }
    }
    return null;
}

/// Find set_front_window via function prologue pattern
fn findSetFrontWindowPattern(text_data: []const u8, text_addr: u64, text_offset: u64) ?struct {
    address: u64,
    file_offset: u64,
    prologue: [32]u8,
    prologue_len: usize,
} {
    // Look for: PACIBSP (7F 23 03 D5) followed by specific stack setup
    // Pattern: 7F 23 03 D5 FF ?? 02 D1 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD ?? 02 91 ?? ?? 00 ?? 08 ?? ?? F9
    // Key distinguishing features:
    // 1. SUB SP, SP, #imm (FF xx 02 D1)
    // 2. STP X22, X23 (F6 57)
    // 3. STP X20, X21 (F4 4F)
    // 4. STP FP, LR (FD 7B)
    // 5. ADD FP, SP, #imm (FD xx 02 91)
    // 6. ADRP instruction (?? ?? 00 ?0) or similar
    // 7. LDR with X8 as dest (08 ?? ?? F9)

    // Start search from beginning of text (patterns can vary between versions)
    const search_start: usize = 0;
    if (text_data.len < 32) return null;
    const search_end: usize = @min(text_data.len - 32, 0x100000);

    var i: usize = search_start;
    while (i < search_end) : (i += 4) {
        // Check for PACIBSP: 7F 23 03 D5
        if (text_data[i] != 0x7F or text_data[i + 1] != 0x23 or
            text_data[i + 2] != 0x03 or text_data[i + 3] != 0xD5) continue;

        // Check for SUB SP, SP, #imm: FF xx 02 D1
        if (text_data[i + 4] != 0xFF) continue;
        if (text_data[i + 6] != 0x02 or text_data[i + 7] != 0xD1) continue;

        // Check for STP X22, X23: F6 57 xx A9
        if (text_data[i + 8] != 0xF6 or text_data[i + 9] != 0x57) continue;
        if (text_data[i + 11] != 0xA9) continue;

        // Check for STP X20, X21: F4 4F xx A9
        if (text_data[i + 12] != 0xF4 or text_data[i + 13] != 0x4F) continue;
        if (text_data[i + 15] != 0xA9) continue;

        // Check for STP FP, LR: FD 7B xx A9
        if (text_data[i + 16] != 0xFD or text_data[i + 17] != 0x7B) continue;
        if (text_data[i + 19] != 0xA9) continue;

        // Check for ADD FP, SP, #imm: FD xx 02 91
        if (text_data[i + 20] != 0xFD) continue;
        if (text_data[i + 22] != 0x02 or text_data[i + 23] != 0x91) continue;

        // Check for LDR with specific pattern ending with 08 ?? ?? F9
        // This distinguishes set_front_window from other similar functions
        // Bytes 28-31 should have: 08 ?? ?? F9 (LDR X8, [...])
        if (i + 32 > text_data.len) continue;
        if (text_data[i + 28] != 0x08) continue;
        if (text_data[i + 31] != 0xF9) continue;

        // Found a match!
        var result: @TypeOf(findSetFrontWindowPattern(text_data, text_addr, text_offset).?) = .{
            .address = text_addr + i,
            .file_offset = text_offset + i,
            .prologue = undefined,
            .prologue_len = @min(32, text_data.len - i),
        };
        @memcpy(result.prologue[0..result.prologue_len], text_data[i..][0..result.prologue_len]);
        return result;
    }
    return null;
}

/// Find fix_animation patch location via FMOV D0, #1.0 pattern
fn findFixAnimationPattern(text_data: []const u8, text_addr: u64) ?u64 {
    // Look for: FMOV D0, #1.0 (00 10 6A 1E) followed by SUB
    // Pattern: 00 10 6A 1E A8 ?? ?? D1
    var i: usize = 0;
    while (i + 8 <= text_data.len) : (i += 4) {
        // FMOV D0, #1.0
        if (text_data[i] != 0x00 or text_data[i + 1] != 0x10 or
            text_data[i + 2] != 0x6A or text_data[i + 3] != 0x1E) continue;

        // Next instruction should be SUB with specific form
        const next = std.mem.readInt(u32, text_data[i + 4 ..][0..4], .little);
        // SUB Xn, Xn, #imm: D1 xx xx xx with specific pattern
        if ((next & 0xFF000000) == 0xD1000000) {
            return text_addr + i;
        }
    }
    return null;
}

pub const DiscoveryResult = struct {
    functions: [7]DiscoveredFunc = [_]DiscoveredFunc{.{}} ** 7,
    prologues: [7][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 7,
    prologue_lens: [7]usize = [_]usize{0} ** 7,
    parse_error: ?anyerror = null,
    diagnostics: [7]Diagnostic = [_]Diagnostic{.{}} ** 7,

    pub const DiscoveredFunc = struct {
        func: patterns.FunctionType = .dock_spaces,
        found: bool = false,
        address: u64 = 0,
        file_offset: u64 = 0,
    };

    pub const Diagnostic = struct {
        method: []const u8 = "",
        selector_found: bool = false,
        selector_name: []const u8 = "",
        fallback_used: bool = false,
        notes: []const u8 = "",
    };

    pub fn foundCount(self: *const DiscoveryResult) usize {
        var count: usize = 0;
        for (self.functions) |f| {
            if (f.found) count += 1;
        }
        return count;
    }

    pub fn toDiagnosticReport(self: *const DiscoveryResult, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        writer.writeAll("SA Pattern Discovery Diagnostics\n") catch {};
        writer.writeAll("═══════════════════════════════════════════════════════════════\n\n") catch {};

        // Summary first
        const found = self.foundCount();
        if (found == 7) {
            writer.writeAll("Status: All 7 functions discovered ✓\n\n") catch {};
        } else {
            writer.print("Status: {}/7 functions discovered (INCOMPLETE)\n\n", .{found}) catch {};
        }

        // Parse error if any
        if (self.parse_error) |err| {
            writer.print("⚠ Parse error: {}\n\n", .{err}) catch {};
        }

        for (self.functions, 0..) |f, i| {
            const func: patterns.FunctionType = @enumFromInt(i);
            const diag = self.diagnostics[i];
            const status = if (f.found) "✓ FOUND" else "✗ NOT FOUND";

            writer.print("{s:<20} {s}\n", .{ func.name(), status }) catch {};

            if (diag.method.len > 0) {
                writer.print("  Method: {s}\n", .{diag.method}) catch {};
            }
            if (diag.selector_name.len > 0) {
                const sel_status = if (diag.selector_found) "yes" else "NO";
                writer.print("  Selector '{s}': {s}\n", .{ diag.selector_name, sel_status }) catch {};
            }
            if (diag.fallback_used) {
                writer.writeAll("  Used fallback pattern search\n") catch {};
            }
            if (diag.notes.len > 0) {
                writer.print("  Note: {s}\n", .{diag.notes}) catch {};
            }
            if (f.found) {
                writer.print("  Address: 0x{x:0>8}\n", .{f.address}) catch {};
            }
            writer.writeAll("\n") catch {};
        }

        // Add suggestions for missing functions
        var missing_count: usize = 0;
        for (self.functions) |f| {
            if (!f.found) missing_count += 1;
        }

        if (missing_count > 0) {
            writer.writeAll("═══════════════════════════════════════════════════════════════\n") catch {};
            writer.writeAll("Suggestions for missing functions:\n\n") catch {};

            for (self.functions, 0..) |f, i| {
                if (f.found) continue;
                const func: patterns.FunctionType = @enumFromInt(i);

                switch (func) {
                    .add_space, .remove_space, .move_space => {
                        writer.print("• {s}: Check if selector name changed in new macOS\n", .{func.name()}) catch {};
                        writer.writeAll("  Run: strings Dock | grep -i 'space'\n") catch {};
                    },
                    .dock_spaces => {
                        writer.print("• {s}: Global ref selector may have changed\n", .{func.name()}) catch {};
                        writer.writeAll("  Run: strings Dock | grep -i 'binding\\|spaces'\n") catch {};
                    },
                    .dppm => {
                        writer.print("• {s}: Pattern search failed - compiler may have changed code\n", .{func.name()}) catch {};
                        writer.writeAll("  Look for ADRP+LDR+LDR sequences to DATA segment\n") catch {};
                    },
                    .set_front_window => {
                        writer.print("• {s}: Prologue pattern changed\n", .{func.name()}) catch {};
                        writer.writeAll("  Look for PACIBSP + large stack frame + specific register saves\n") catch {};
                    },
                    .fix_animation => {
                        writer.print("• {s}: FMOV D0, #1.0 pattern not found\n", .{func.name()}) catch {};
                        writer.writeAll("  Animation timing code may have been restructured\n") catch {};
                    },
                }
                writer.writeAll("\n") catch {};
            }
        }

        return fbs.getWritten();
    }

    pub fn toJson(self: *const DiscoveryResult, allocator: std.mem.Allocator, os: patterns.OSVersion) ![]u8 {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        try writer.writeAll("{\n");
        try writer.print("  \"os_version\": \"{}.{}.{}\",\n", .{ os.major, os.minor, os.patch });
        try writer.writeAll("  \"arch\": \"arm64\",\n");
        try writer.writeAll("  \"discovered\": {\n");

        var first = true;
        for (self.functions, 0..) |f, i| {
            if (f.found) {
                if (!first) try writer.writeAll(",\n");
                first = false;

                // Convert prologue to pattern string
                const pattern = objc_analyzer.MachOBinary.prologueToPattern(self.prologues[i][0..self.prologue_lens[i]]);
                const pattern_str = std.mem.sliceTo(&pattern, 0);

                try writer.print("    \"{s}\": {{\n", .{f.func.name()});
                try writer.print("      \"address\": \"0x{x:0>8}\",\n", .{f.address});
                try writer.print("      \"file_offset\": \"0x{x:0>8}\",\n", .{f.file_offset});
                try writer.print("      \"pattern\": \"{s}\"\n", .{pattern_str});
                try writer.writeAll("    }");
            }
        }

        try writer.writeAll("\n  }\n");
        try writer.writeAll("}\n");

        const written = fbs.getWritten();
        const output = try allocator.alloc(u8, written.len);
        @memcpy(output, written);
        return output;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "compile simple pattern" {
    const allocator = std.testing.allocator;

    var p = try compilePattern(allocator, "7F 23 03 D5");
    defer p.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), p.len);
    try std.testing.expectEqual(@as(u8, 0x7F), p.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x23), p.bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x03), p.bytes[2]);
    try std.testing.expectEqual(@as(u8, 0xD5), p.bytes[3]);

    // All should be required (mask = 1)
    for (p.mask) |m| {
        try std.testing.expectEqual(@as(u8, 1), m);
    }
}

test "compile pattern with wildcards" {
    const allocator = std.testing.allocator;

    var p = try compilePattern(allocator, "7F ?? 03 ??");
    defer p.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), p.len);
    try std.testing.expectEqual(@as(u8, 1), p.mask[0]); // 7F must match
    try std.testing.expectEqual(@as(u8, 0), p.mask[1]); // wildcard
    try std.testing.expectEqual(@as(u8, 1), p.mask[2]); // 03 must match
    try std.testing.expectEqual(@as(u8, 0), p.mask[3]); // wildcard
}

test "find pattern in data" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x00, 0x00, 0x7F, 0x23, 0x03, 0xD5, 0x00, 0x00 };

    var p = try compilePattern(allocator, "7F 23 03 D5");
    defer p.deinit(allocator);

    const found = findPattern(&data, p, data.len);
    try std.testing.expectEqual(@as(?usize, 2), found);
}

test "find pattern with wildcards" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x00, 0x7F, 0xAB, 0x03, 0xCD, 0x00 };

    var p = try compilePattern(allocator, "7F ?? 03 ??");
    defer p.deinit(allocator);

    const found = findPattern(&data, p, data.len);
    try std.testing.expectEqual(@as(?usize, 1), found);
}

test "pattern not found" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

    var p = try compilePattern(allocator, "7F 23 03 D5");
    defer p.deinit(allocator);

    const found = findPattern(&data, p, data.len);
    try std.testing.expect(found == null);
}

test "extractArm64Slice non-FAT returns original" {
    // Mach-O 64 magic (not FAT)
    var data = [_]u8{ 0xCF, 0xFA, 0xED, 0xFE } ++ [_]u8{0} ** 100;
    const result = extractArm64Slice(&data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(data.len, result.?.len);
}

test "extractArm64Slice too small returns input" {
    var data = [_]u8{ 0x00, 0x00 };
    const result = extractArm64Slice(&data);
    try std.testing.expectEqual(data.len, result.?.len);
}

test "swap32" {
    try std.testing.expectEqual(@as(u32, 0x78563412), swap32(0x12345678));
    try std.testing.expectEqual(@as(u32, 0x00000001), swap32(0x01000000));
}

test "swapI32" {
    try std.testing.expectEqual(@as(i32, 0x78563412), swapI32(0x12345678));
}

test "hexDigit" {
    try std.testing.expectEqual(@as(?u8, 0), hexDigit('0'));
    try std.testing.expectEqual(@as(?u8, 9), hexDigit('9'));
    try std.testing.expectEqual(@as(?u8, 10), hexDigit('A'));
    try std.testing.expectEqual(@as(?u8, 10), hexDigit('a'));
    try std.testing.expectEqual(@as(?u8, 15), hexDigit('F'));
    try std.testing.expectEqual(@as(?u8, 15), hexDigit('f'));
    try std.testing.expectEqual(@as(?u8, null), hexDigit('G'));
}

test "compilePattern empty returns error" {
    const allocator = std.testing.allocator;
    const result = compilePattern(allocator, "");
    try std.testing.expectError(error.EmptyPattern, result);
}

test "compilePattern invalid hex returns error" {
    const allocator = std.testing.allocator;
    const result = compilePattern(allocator, "GG HH");
    try std.testing.expectError(error.InvalidHex, result);
}

test "AnalysisResult foundCount" {
    var result = AnalysisResult{
        .os = .{ .major = 15, .minor = 0, .patch = 0 },
        .arch = .arm64,
        .results = undefined,
    };
    for (&result.results, 0..) |*r, i| {
        r.* = .{
            .func = @enumFromInt(i),
            .found = i < 3, // First 3 found
        };
    }
    try std.testing.expectEqual(@as(usize, 3), result.foundCount());
    try std.testing.expect(!result.allFound());
}

test "DiscoveryResult foundCount" {
    var result = DiscoveryResult{};
    result.functions[0].found = true;
    result.functions[2].found = true;
    try std.testing.expectEqual(@as(usize, 2), result.foundCount());
}

// Integration test - runs against actual Dock binary on macOS
test "integration: discover functions from Dock" {
    // Skip if not on macOS or Dock doesn't exist
    const dock_path = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";
    const dock_file = std.fs.openFileAbsolute(dock_path, .{}) catch {
        // Not on macOS or Dock not accessible - skip test
        return;
    };
    defer dock_file.close();

    const allocator = std.testing.allocator;

    // Read the Dock binary
    const dock_data = std.fs.cwd().readFileAlloc(allocator, dock_path, 32 * 1024 * 1024) catch {
        return; // Can't read, skip
    };
    defer allocator.free(dock_data);

    // Extract arm64 slice
    const binary_data = extractArm64Slice(dock_data) orelse {
        try std.testing.expect(false); // Should have arm64 slice on modern macOS
        return;
    };

    // Verify it's a valid Mach-O
    try std.testing.expect(binary_data.len > 1024);

    // Run discovery
    const discovery = discoverFunctions(allocator, binary_data) catch |err| {
        std.log.err("Discovery error: {}", .{err});
        try std.testing.expect(false);
        return;
    };

    // Should find at least the ObjC selector-based functions
    // (add_space, remove_space, move_space)
    const found = discovery.foundCount();
    std.log.info("Integration test: discovered {}/7 functions", .{found});

    // We expect at least 3 functions (the ObjC ones) on any macOS version
    try std.testing.expect(found >= 3);

    // Verify the discovered functions have reasonable addresses
    for (discovery.functions) |f| {
        if (f.found) {
            // Address should be in TEXT segment range (0x100xxxxxx)
            try std.testing.expect(f.address >= 0x100000000);
            try std.testing.expect(f.address < 0x110000000);
        }
    }
}
