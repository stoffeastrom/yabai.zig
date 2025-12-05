const std = @import("std");
const c = @import("../platform/c.zig");

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

const SymtabCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    symoff: u32,
    nsyms: u32,
    stroff: u32,
    strsize: u32,
};

const Nlist64 = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: i16,
    n_value: u64,
};

const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;
const SEG_LINKEDIT = "__LINKEDIT";

extern fn _dyld_image_count() u32;
extern fn _dyld_get_image_name(image_index: u32) ?[*:0]const u8;
extern fn _dyld_get_image_header(image_index: u32) ?*const MachHeader64;
extern fn _dyld_get_image_vmaddr_slide(image_index: u32) isize;

fn findImageHeader(target_name: []const u8) ?struct { header: *const MachHeader64, slide: isize } {
    const image_count = _dyld_image_count();

    var i: u32 = 0;
    while (i < image_count) : (i += 1) {
        const image_name_ptr = _dyld_get_image_name(i) orelse continue;
        const name_slice = std.mem.span(image_name_ptr);

        if (std.mem.eql(u8, name_slice, target_name)) {
            const header = _dyld_get_image_header(i) orelse continue;
            const slide = _dyld_get_image_vmaddr_slide(i);
            return .{ .header = header, .slide = slide };
        }
    }

    return null;
}

fn findLinkeditSegment(header: *const MachHeader64) ?*const SegmentCommand64 {
    var offset: usize = @sizeOf(MachHeader64);
    const base = @intFromPtr(header);

    var i: u32 = 0;
    while (i < header.ncmds) : (i += 1) {
        const cmd: *const LoadCommand = @ptrFromInt(base + offset);

        if (cmd.cmd == LC_SEGMENT_64) {
            const segment: *const SegmentCommand64 = @ptrFromInt(base + offset);
            if (std.mem.eql(u8, segment.segname[0..SEG_LINKEDIT.len], SEG_LINKEDIT)) {
                return segment;
            }
        }

        offset += cmd.cmdsize;
    }

    return null;
}

fn findSymtabCommand(header: *const MachHeader64) ?*const SymtabCommand {
    var offset: usize = @sizeOf(MachHeader64);
    const base = @intFromPtr(header);

    var i: u32 = 0;
    while (i < header.ncmds) : (i += 1) {
        const cmd: *const LoadCommand = @ptrFromInt(base + offset);

        if (cmd.cmd == LC_SYMTAB) {
            return @ptrFromInt(base + offset);
        }

        offset += cmd.cmdsize;
    }

    return null;
}

pub fn findSymbol(comptime T: type, target_image: []const u8, target_symbol: []const u8) ?T {
    const result = findImageHeader(target_image) orelse return null;
    const header = result.header;
    const slide = result.slide;

    const linkedit_segment = findLinkeditSegment(header) orelse return null;
    const symtab_command = findSymtabCommand(header) orelse return null;

    const base: usize = @intCast(@as(isize, @intCast(linkedit_segment.vmaddr -| linkedit_segment.fileoff)) + slide);
    const symbol_str: [*]const u8 = @ptrFromInt(base + symtab_command.stroff);
    const symbol_sym: [*]const Nlist64 = @ptrFromInt(base + symtab_command.symoff);

    var i: u32 = 0;
    while (i < symtab_command.nsyms) : (i += 1) {
        const list = &symbol_sym[i];
        const symbol_name_ptr: [*:0]const u8 = @ptrCast(symbol_str + list.n_strx);
        const symbol_name = std.mem.span(symbol_name_ptr);

        if (std.mem.eql(u8, symbol_name, target_symbol)) {
            const addr: usize = @intCast(@as(isize, @intCast(list.n_value)) + slide);
            return @ptrFromInt(addr);
        }
    }

    return null;
}
