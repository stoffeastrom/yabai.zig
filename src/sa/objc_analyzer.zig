const std = @import("std");

/// Mach-O 64-bit header
const MachHeader64 = extern struct {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

const LoadCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
};

const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
};

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

const MH_MAGIC_64: u32 = 0xfeedfacf;
const LC_SEGMENT_64: u32 = 0x19;

/// Information about a found selector reference
pub const SelectorRef = struct {
    name: []const u8,
    selref_addr: u64, // Virtual address of the selref entry
    selref_file_offset: u64, // File offset of selref entry
};

/// Information about a code reference to a selector
pub const CodeXref = struct {
    selector: []const u8,
    xref_addr: u64, // Address of instruction referencing selector
    xref_file_offset: u64,
    func_start_addr: u64, // Detected function start
    func_start_file_offset: u64,
};

/// Result of function discovery
pub const DiscoveredFunction = struct {
    name: []const u8, // Selector name used to find it
    address: u64, // Virtual address
    file_offset: u64,
    prologue: [32]u8, // First 32 bytes of function
    prologue_len: usize,
};

/// Parsed Mach-O binary for analysis
pub const MachOBinary = struct {
    data: []const u8,
    header: *const MachHeader64,
    text_section: ?SectionInfo = null,
    methname_section: ?SectionInfo = null,
    selrefs_section: ?SectionInfo = null,

    const SectionInfo = struct {
        addr: u64,
        size: u64,
        offset: u64,
    };

    pub fn parse(data: []const u8) !MachOBinary {
        if (data.len < @sizeOf(MachHeader64)) return error.TooSmall;

        const header: *const MachHeader64 = @ptrCast(@alignCast(data.ptr));
        if (header.magic != MH_MAGIC_64) return error.NotMachO64;

        var binary = MachOBinary{
            .data = data,
            .header = header,
        };

        // Parse load commands to find sections
        var cmd_offset: usize = @sizeOf(MachHeader64);
        for (0..header.ncmds) |_| {
            if (cmd_offset + @sizeOf(LoadCommand) > data.len) break;

            const cmd: *const LoadCommand = @ptrCast(@alignCast(data.ptr + cmd_offset));

            if (cmd.cmd == LC_SEGMENT_64) {
                const seg: *const SegmentCommand64 = @ptrCast(@alignCast(data.ptr + cmd_offset));

                // Parse sections within segment
                var sect_offset = cmd_offset + @sizeOf(SegmentCommand64);
                for (0..seg.nsects) |_| {
                    if (sect_offset + @sizeOf(Section64) > data.len) break;

                    const sect: *const Section64 = @ptrCast(@alignCast(data.ptr + sect_offset));
                    const sectname = std.mem.sliceTo(&sect.sectname, 0);

                    if (std.mem.eql(u8, sectname, "__text")) {
                        binary.text_section = .{
                            .addr = sect.addr,
                            .size = sect.size,
                            .offset = sect.offset,
                        };
                    } else if (std.mem.eql(u8, sectname, "__objc_methname")) {
                        binary.methname_section = .{
                            .addr = sect.addr,
                            .size = sect.size,
                            .offset = sect.offset,
                        };
                    } else if (std.mem.eql(u8, sectname, "__objc_selrefs")) {
                        binary.selrefs_section = .{
                            .addr = sect.addr,
                            .size = sect.size,
                            .offset = sect.offset,
                        };
                    }

                    sect_offset += @sizeOf(Section64);
                }
            }

            cmd_offset += cmd.cmdsize;
        }

        return binary;
    }

    /// Find the virtual address of a selector reference by name
    pub fn findSelectorRef(self: *const MachOBinary, selector_name: []const u8) ?SelectorRef {
        const methname = self.methname_section orelse return null;
        const selrefs = self.selrefs_section orelse return null;

        // First, find the selector string in __objc_methname
        const methname_data = self.data[methname.offset..][0..@intCast(methname.size)];
        const selector_offset = std.mem.indexOf(u8, methname_data, selector_name) orelse return null;

        // Verify it's a complete string (null terminated or at start)
        if (selector_offset > 0 and methname_data[selector_offset - 1] != 0) return null;
        const end_pos = selector_offset + selector_name.len;
        if (end_pos < methname_data.len and methname_data[end_pos] != 0) return null;

        // Calculate the FILE OFFSET of this string (not vmaddr)
        // Modern Mach-O with chained fixups stores file offsets in selrefs
        const string_file_offset = methname.offset + selector_offset;

        // Now search __objc_selrefs for a pointer to this string
        const selrefs_data = self.data[selrefs.offset..][0..@intCast(selrefs.size)];
        const num_refs = selrefs.size / 8;

        for (0..@intCast(num_refs)) |i| {
            const ref_offset = i * 8;
            const ptr_bytes = selrefs_data[ref_offset..][0..8];
            const ptr_value = std.mem.readInt(u64, ptr_bytes, .little);

            // Chained fixups format: high bits are metadata, low 48 bits are file offset
            const file_offset_in_ref = ptr_value & 0x0000FFFFFFFFFFFF;
            if (file_offset_in_ref == string_file_offset) {
                return SelectorRef{
                    .name = selector_name,
                    .selref_addr = selrefs.addr + ref_offset,
                    .selref_file_offset = selrefs.offset + ref_offset,
                };
            }
        }

        return null;
    }

    /// Find code that references a selector and identify the containing function
    pub fn findFunctionForSelector(self: *const MachOBinary, allocator: std.mem.Allocator, selector_name: []const u8) !?DiscoveredFunction {
        const selref = self.findSelectorRef(selector_name) orelse return null;
        const text = self.text_section orelse return null;

        _ = allocator;

        // Search __text for ADRP+LDR sequences that load from the selref address
        const text_data = self.data[text.offset..][0..@intCast(text.size)];

        // On ARM64, selector refs are typically loaded via:
        //   ADRP Xn, page
        //   LDR Xn, [Xn, offset]
        // or via:
        //   ADRP Xn, page
        //   ADD Xn, Xn, offset (for GOT-indirect)

        // We'll search for any instruction sequence that could reference the selref
        // by looking for the page number in ADRP instructions

        const selref_page = selref.selref_addr & ~@as(u64, 0xFFF);
        const selref_page_offset: u12 = @intCast(selref.selref_addr & 0xFFF);

        var i: usize = 0;
        while (i + 8 <= text_data.len) : (i += 4) {
            const instr = std.mem.readInt(u32, text_data[i..][0..4], .little);

            // Check for ADRP instruction: 1xx1 0000 xxxx xxxx xxxx xxxx xxxd dddd
            if ((instr & 0x9F000000) == 0x90000000) {
                // Decode ADRP
                const pc = text.addr + i;
                const pc_page = pc & ~@as(u64, 0xFFF);
                const immlo: u64 = (instr >> 29) & 0x3;
                const immhi_raw: u32 = (instr >> 5) & 0x7FFFF;
                const immhi: i64 = @as(i64, @as(i32, @bitCast(immhi_raw << 13)) >> 13);
                const imm: i64 = (immhi << 14) | @as(i64, @intCast(immlo << 12));
                const target_page: u64 = @intCast(@as(i64, @intCast(pc_page)) +% imm);

                if (target_page == selref_page) {
                    // Check next instruction for LDR with matching offset
                    if (i + 8 <= text_data.len) {
                        const next_instr = std.mem.readInt(u32, text_data[i + 4 ..][0..4], .little);

                        // LDR (immediate, unsigned offset): 1x11 1001 01xx xxxx xxxx xxnn nnnt tttt
                        if ((next_instr & 0xFFC00000) == 0xF9400000) {
                            const ldr_imm: u12 = @intCast((next_instr >> 10) & 0xFFF);
                            const offset = @as(u64, ldr_imm) * 8; // Scale by 8 for 64-bit LDR

                            if (offset == selref_page_offset) {
                                // Found a reference! Now walk backwards to find function start
                                const func_info = self.findFunctionStart(i);
                                const func_file_offset = text.offset + func_info.offset;

                                var result = DiscoveredFunction{
                                    .name = selector_name,
                                    .address = text.addr + func_info.offset,
                                    .file_offset = func_file_offset,
                                    .prologue = undefined,
                                    .prologue_len = 0,
                                };

                                // Copy prologue bytes
                                const prologue_len = @min(32, text_data.len - func_info.offset);
                                @memcpy(result.prologue[0..prologue_len], text_data[func_info.offset..][0..prologue_len]);
                                result.prologue_len = prologue_len;

                                return result;
                            }
                        }
                    }
                }
            }
        }

        return null;
    }

    /// Walk backwards from an instruction offset to find the function start
    fn findFunctionStart(self: *const MachOBinary, instr_offset: usize) struct { offset: usize } {
        const text = self.text_section orelse return .{ .offset = instr_offset };
        const text_data = self.data[text.offset..][0..@intCast(text.size)];

        // Walk backwards looking for common function prologues
        var offset = instr_offset;
        while (offset >= 4) {
            offset -= 4;
            const instr = std.mem.readInt(u32, text_data[offset..][0..4], .little);

            // Check for PACIBSP (0xD503237F) - ARM64e function entry
            if (instr == 0xD503237F) {
                return .{ .offset = offset };
            }

            // Check for BTI (0xD503245F) - branch target identification
            if (instr == 0xD503245F) {
                return .{ .offset = offset };
            }

            // Check for STP with FP/LR save pattern: STP X29, X30, [SP, #-N]!
            // 1010 1001 1xxx xxxx x111 1011 1111 1101
            if ((instr & 0xFFE07FFF) == 0xA9807BFD) {
                return .{ .offset = offset };
            }

            // Check for SUB SP, SP, #N (stack allocation)
            // 1101 0001 00xx xxxx xxxx xx11 1111 1111
            if ((instr & 0xFF0003FF) == 0xD10003FF) {
                // This might be function start, but check for prologue before it
                if (offset >= 4) {
                    const prev = std.mem.readInt(u32, text_data[offset - 4 ..][0..4], .little);
                    // If previous is PACIBSP or BTI, that's the real start
                    if (prev == 0xD503237F or prev == 0xD503245F) {
                        return .{ .offset = offset - 4 };
                    }
                }
                return .{ .offset = offset };
            }

            // Safety limit - don't search more than 4KB back
            if (instr_offset - offset > 4096) {
                return .{ .offset = instr_offset };
            }
        }

        return .{ .offset = instr_offset };
    }

    /// Represents a global data reference found in code
    pub const GlobalRef = struct {
        address: u64, // Virtual address of the global
        instr_offset: usize, // Offset in __text where reference was found
    };

    /// Find global data references (ADRP+LDR/ADD patterns) within a function
    /// Returns addresses of globals loaded in the first N instructions
    pub fn findGlobalRefsInFunction(self: *const MachOBinary, func_offset: usize, max_instrs: usize) [8]?GlobalRef {
        var refs: [8]?GlobalRef = [_]?GlobalRef{null} ** 8;
        var ref_count: usize = 0;

        const text = self.text_section orelse return refs;
        const text_data = self.data[text.offset..][0..@intCast(text.size)];

        const max_offset = @min(func_offset + max_instrs * 4, text_data.len - 4);
        var i: usize = func_offset;

        while (i < max_offset and ref_count < 8) : (i += 4) {
            const instr = std.mem.readInt(u32, text_data[i..][0..4], .little);

            // Check for ADRP instruction
            if ((instr & 0x9F000000) == 0x90000000) {
                const pc = text.addr + i;
                const pc_page = pc & ~@as(u64, 0xFFF);
                const immlo: u64 = (instr >> 29) & 0x3;
                const immhi_raw: u32 = (instr >> 5) & 0x7FFFF;
                const immhi: i64 = @as(i64, @as(i32, @bitCast(immhi_raw << 13)) >> 13);
                const imm: i64 = (immhi << 14) | @as(i64, @intCast(immlo << 12));
                const target_page: u64 = @intCast(@as(i64, @intCast(pc_page)) +% imm);
                const rd: u5 = @truncate(instr & 0x1F);

                // Look at next instruction for ADD or LDR using same register
                if (i + 4 < max_offset) {
                    const next_instr = std.mem.readInt(u32, text_data[i + 4 ..][0..4], .little);

                    // ADD immediate: 1001 0001 00ii iiii iiii iinn nnnd dddd
                    if ((next_instr & 0xFFC00000) == 0x91000000) {
                        const add_rd: u5 = @truncate(next_instr & 0x1F);
                        const add_rn: u5 = @truncate((next_instr >> 5) & 0x1F);
                        if (add_rn == rd) {
                            const add_imm: u12 = @truncate((next_instr >> 10) & 0xFFF);
                            const global_addr = target_page + add_imm;
                            refs[ref_count] = .{ .address = global_addr, .instr_offset = i };
                            ref_count += 1;
                            _ = add_rd;
                        }
                    }

                    // LDR (immediate, unsigned offset): 1x11 1001 01ii iiii iiii iinn nnnd dddd
                    if ((next_instr & 0xFFC00000) == 0xF9400000) {
                        const ldr_rn: u5 = @truncate((next_instr >> 5) & 0x1F);
                        if (ldr_rn == rd) {
                            const ldr_imm: u12 = @truncate((next_instr >> 10) & 0xFFF);
                            const offset_scaled = @as(u64, ldr_imm) * 8; // 64-bit LDR scales by 8
                            const global_addr = target_page + offset_scaled;
                            refs[ref_count] = .{ .address = global_addr, .instr_offset = i };
                            ref_count += 1;
                        }
                    }
                }
            }
        }

        return refs;
    }

    /// Convert prologue bytes to a pattern string with wildcards for variable parts
    pub fn prologueToPattern(prologue: []const u8) [128]u8 {
        var pattern: [128]u8 = undefined;
        var pos: usize = 0;

        for (prologue, 0..) |byte, i| {
            // Add space between bytes (except first)
            if (i > 0 and pos < pattern.len) {
                pattern[pos] = ' ';
                pos += 1;
            }

            if (pos + 2 > pattern.len) break;

            // Determine if this byte should be wildcarded
            // We wildcard: register numbers, immediate values that vary
            const instr_pos = i % 4;
            const should_wildcard = switch (instr_pos) {
                0 => false, // Usually opcode bits
                1 => shouldWildcardByte(prologue, i),
                2 => shouldWildcardByte(prologue, i),
                3 => false, // Usually opcode bits
                else => false,
            };

            if (should_wildcard) {
                pattern[pos] = '?';
                pattern[pos + 1] = '?';
            } else {
                pattern[pos] = hexChar(@as(u4, @truncate(byte >> 4)));
                pattern[pos + 1] = hexChar(@as(u4, @truncate(byte & 0xF)));
            }
            pos += 2;
        }

        // Null terminate
        if (pos < pattern.len) pattern[pos] = 0;

        return pattern;
    }

    fn shouldWildcardByte(prologue: []const u8, index: usize) bool {
        // Get the full instruction
        const instr_start = (index / 4) * 4;
        if (instr_start + 4 > prologue.len) return false;

        const instr = std.mem.readInt(u32, prologue[instr_start..][0..4], .little);

        // ADRP - wildcard the immediate (bytes 1-2 and parts of 0,3)
        if ((instr & 0x9F000000) == 0x90000000) return true;

        // BL/B - wildcard the offset
        if ((instr & 0xFC000000) == 0x94000000) return true; // BL
        if ((instr & 0xFC000000) == 0x14000000) return true; // B

        // ADD immediate - might have variable offset
        if ((instr & 0xFF000000) == 0x91000000) {
            const byte_in_instr = index % 4;
            return byte_in_instr == 1 or byte_in_instr == 2;
        }

        return false;
    }

    fn hexChar(nibble: u4) u8 {
        const n: u8 = nibble;
        return if (n < 10) '0' + n else 'A' + n - 10;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MachOBinary basic parse" {
    // Create a minimal valid Mach-O header
    var data: [4096]u8 = undefined;
    @memset(&data, 0);

    const header: *MachHeader64 = @ptrCast(@alignCast(&data));
    header.magic = MH_MAGIC_64;
    header.ncmds = 0;
    header.sizeofcmds = 0;

    const binary = try MachOBinary.parse(&data);
    try std.testing.expect(binary.header.magic == MH_MAGIC_64);
}

test "prologue to pattern" {
    // Test with a simple prologue
    const prologue = [_]u8{ 0x7F, 0x23, 0x03, 0xD5, 0xFF, 0xC3, 0x01, 0xD1 };
    const pattern = MachOBinary.prologueToPattern(&prologue);
    const pattern_str = std.mem.sliceTo(&pattern, 0);

    // Should produce something like "7F 23 03 D5 FF ?? ?? D1" or similar
    try std.testing.expect(pattern_str.len > 0);
}

test "parse invalid magic returns error" {
    var data: [4096]u8 = undefined;
    @memset(&data, 0);

    // Set invalid magic
    const header: *MachHeader64 = @ptrCast(@alignCast(&data));
    header.magic = 0xDEADBEEF;

    const result = MachOBinary.parse(&data);
    try std.testing.expectError(error.NotMachO64, result);
}

test "parse too small returns error" {
    var data: [16]u8 = undefined;
    @memset(&data, 0);

    const result = MachOBinary.parse(&data);
    try std.testing.expectError(error.TooSmall, result);
}

test "shouldWildcardByte for ADRP" {
    // ADRP X0, #0 = 0x90000000
    const prologue = [_]u8{ 0x00, 0x00, 0x00, 0x90 };
    try std.testing.expect(MachOBinary.shouldWildcardByte(&prologue, 1));
    try std.testing.expect(MachOBinary.shouldWildcardByte(&prologue, 2));
}

test "shouldWildcardByte for BL" {
    // BL #0 = 0x94000000
    const prologue = [_]u8{ 0x00, 0x00, 0x00, 0x94 };
    try std.testing.expect(MachOBinary.shouldWildcardByte(&prologue, 1));
}

test "hexChar conversion" {
    try std.testing.expectEqual(@as(u8, '0'), MachOBinary.hexChar(0));
    try std.testing.expectEqual(@as(u8, '9'), MachOBinary.hexChar(9));
    try std.testing.expectEqual(@as(u8, 'A'), MachOBinary.hexChar(10));
    try std.testing.expectEqual(@as(u8, 'F'), MachOBinary.hexChar(15));
}
