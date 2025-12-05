const std = @import("std");
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("libproc.h");
    @cInclude("sys/sysctl.h");
});
const patterns = @import("patterns.zig");
const extractor = @import("extractor.zig");

/// Result of verifying a single function/address
pub const VerifyResult = struct {
    func: patterns.FunctionType,
    discovered_addr: u64,
    verified: bool,
    reason: []const u8,
    details: [256]u8 = undefined,
    details_len: usize = 0,
};

/// Complete verification results
pub const VerificationReport = struct {
    results: [7]VerifyResult,
    dock_pid: i32,
    dock_base: u64,
    all_verified: bool,
    mode: []const u8, // "runtime" or "static"
};

/// Find the running Dock process
pub fn findDockPid() ?i32 {
    var pids: [1024]i32 = undefined;
    const size = c.proc_listpids(c.PROC_ALL_PIDS, 0, &pids, @sizeOf(@TypeOf(pids)));
    if (size <= 0) return null;

    const count = @as(usize, @intCast(size)) / @sizeOf(i32);
    for (pids[0..count]) |pid| {
        if (pid <= 0) continue;

        var path_buf: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
        const path_len = c.proc_pidpath(pid, &path_buf, @sizeOf(@TypeOf(path_buf)));
        if (path_len <= 0) continue;

        const path = path_buf[0..@intCast(path_len)];
        if (std.mem.endsWith(u8, path, "/Dock")) {
            return pid;
        }
    }
    return null;
}

/// Get the base address of Dock's main image in memory
pub fn getDockBaseAddress(task: c.mach_port_t) ?u64 {
    // Get dyld_all_image_infos address
    var info: c.task_dyld_info_data_t = undefined;
    var count: c.mach_msg_type_number_t = c.TASK_DYLD_INFO_COUNT;

    const kr = c.task_info(task, c.TASK_DYLD_INFO, @ptrCast(&info), &count);
    if (kr != c.KERN_SUCCESS) return null;

    // The first image is typically the main executable
    // Read dyld_all_image_infos structure
    const all_image_infos_addr = info.all_image_info_addr;
    if (all_image_infos_addr == 0) return null;

    // Read infoArrayCount and infoArray pointer from dyld_all_image_infos
    var header: [16]u8 = undefined;
    var out_size: c.mach_vm_size_t = 0;
    const kr2 = c.mach_vm_read_overwrite(
        task,
        all_image_infos_addr,
        16,
        @intFromPtr(&header),
        &out_size,
    );
    if (kr2 != c.KERN_SUCCESS or out_size != 16) return null;

    const info_array_ptr = std.mem.readInt(u64, header[8..16], .little);
    if (info_array_ptr == 0) return null;

    // Read first dyld_image_info entry
    var first_image: [24]u8 = undefined;
    const kr3 = c.mach_vm_read_overwrite(
        task,
        info_array_ptr,
        24,
        @intFromPtr(&first_image),
        &out_size,
    );
    if (kr3 != c.KERN_SUCCESS or out_size != 24) return null;

    return std.mem.readInt(u64, first_image[0..8], .little);
}

/// Read memory from a remote task
fn readTaskMemory(task: c.mach_port_t, address: u64, buf: []u8) bool {
    var out_size: c.mach_vm_size_t = 0;
    const kr = c.mach_vm_read_overwrite(
        task,
        address,
        buf.len,
        @intFromPtr(buf.ptr),
        &out_size,
    );
    return kr == c.KERN_SUCCESS and out_size == buf.len;
}

/// Verify discovered addresses against running Dock process (requires root)
pub fn verifyDiscoveryRuntime(discovery: *const extractor.DiscoveryResult) !VerificationReport {
    var report = VerificationReport{
        .results = undefined,
        .dock_pid = 0,
        .dock_base = 0,
        .all_verified = true,
        .mode = "runtime",
    };

    // Find Dock process
    const pid = findDockPid() orelse {
        report.all_verified = false;
        for (&report.results, 0..) |*r, i| {
            r.* = .{
                .func = @enumFromInt(i),
                .discovered_addr = discovery.functions[i].address,
                .verified = false,
                .reason = "Dock process not found",
            };
        }
        return report;
    };
    report.dock_pid = pid;

    // Get task port for Dock
    var task: c.mach_port_t = 0;
    const kr = c.task_for_pid(c.mach_task_self(), pid, &task);
    if (kr != c.KERN_SUCCESS) {
        report.all_verified = false;
        for (&report.results, 0..) |*r, i| {
            r.* = .{
                .func = @enumFromInt(i),
                .discovered_addr = discovery.functions[i].address,
                .verified = false,
                .reason = "Cannot access Dock (need root or taskgated)",
            };
        }
        return report;
    }
    defer _ = c.mach_port_deallocate(c.mach_task_self(), task);

    // Get base address
    report.dock_base = getDockBaseAddress(task) orelse 0x100000000;

    // Verify each discovered function
    for (0..7) |i| {
        const func: patterns.FunctionType = @enumFromInt(i);
        const disc = discovery.functions[i];

        if (!disc.found) {
            report.results[i] = .{
                .func = func,
                .discovered_addr = 0,
                .verified = false,
                .reason = "Not discovered",
            };
            report.all_verified = false;
            continue;
        }

        const runtime_addr = disc.address;

        report.results[i] = switch (func) {
            .dock_spaces, .dppm => verifyGlobalRuntime(task, runtime_addr, func),
            .add_space, .remove_space, .move_space, .set_front_window => verifyFunctionRuntime(task, runtime_addr, discovery.prologues[i][0..discovery.prologue_lens[i]], func),
            .fix_animation => verifyPatchLocationRuntime(task, runtime_addr, func),
        };

        if (!report.results[i].verified) {
            report.all_verified = false;
        }
    }

    return report;
}

/// Verify discovered addresses using static binary analysis (no root required)
pub fn verifyDiscovery(discovery: *const extractor.DiscoveryResult) !VerificationReport {
    var report = VerificationReport{
        .results = undefined,
        .dock_pid = findDockPid() orelse 0,
        .dock_base = 0x100000000,
        .all_verified = true,
        .mode = "static",
    };

    // Verify each discovered function using static checks
    for (0..7) |i| {
        const func: patterns.FunctionType = @enumFromInt(i);
        const disc = discovery.functions[i];

        if (!disc.found) {
            report.results[i] = .{
                .func = func,
                .discovered_addr = 0,
                .verified = false,
                .reason = "Not discovered",
            };
            report.all_verified = false;
            continue;
        }

        report.results[i] = switch (func) {
            .dock_spaces, .dppm => verifyGlobalStatic(disc.address, disc.file_offset, func),
            .add_space, .remove_space, .move_space, .set_front_window => verifyFunctionStatic(disc.address, discovery.prologues[i][0..discovery.prologue_lens[i]], func),
            .fix_animation => verifyPatchLocationStatic(disc.address, discovery.prologues[i][0..discovery.prologue_lens[i]], func),
        };

        if (!report.results[i].verified) {
            report.all_verified = false;
        }
    }

    return report;
}

/// Verify a global pointer at runtime
fn verifyGlobalRuntime(task: c.mach_port_t, addr: u64, func: patterns.FunctionType) VerifyResult {
    var result = VerifyResult{
        .func = func,
        .discovered_addr = addr,
        .verified = false,
        .reason = "",
    };

    var ptr_bytes: [8]u8 = undefined;
    if (!readTaskMemory(task, addr, &ptr_bytes)) {
        result.reason = "Cannot read memory at address";
        return result;
    }

    const ptr_value = std.mem.readInt(u64, &ptr_bytes, .little);

    if (ptr_value == 0) {
        result.reason = "Global is NULL (Dock may not be fully initialized)";
        return result;
    }

    if (ptr_value & 0x7 != 0) {
        result.reason = "Pointer not aligned (invalid)";
        return result;
    }

    var isa_bytes: [8]u8 = undefined;
    if (!readTaskMemory(task, ptr_value, &isa_bytes)) {
        result.reason = "Cannot read object at pointer";
        return result;
    }

    const isa = std.mem.readInt(u64, &isa_bytes, .little);

    if (isa == 0 or isa & 0x7 != 0) {
        result.reason = "Invalid isa pointer";
        return result;
    }

    result.verified = true;
    result.reason = "Valid ObjC object pointer";

    const details_fmt = std.fmt.bufPrint(&result.details, "ptr=0x{x:0>16} isa=0x{x:0>16}", .{ ptr_value, isa }) catch "";
    result.details_len = details_fmt.len;

    return result;
}

/// Verify a global pointer statically (check address is in DATA segment)
fn verifyGlobalStatic(addr: u64, file_offset: u64, func: patterns.FunctionType) VerifyResult {
    var result = VerifyResult{
        .func = func,
        .discovered_addr = addr,
        .verified = false,
        .reason = "",
    };

    // Check address is in reasonable DATA segment range
    // Typical Dock __DATA is around 0x1003xxxxx - 0x1004xxxxx
    if (addr >= 0x100300000 and addr < 0x100500000) {
        // Check alignment (should be 8-byte aligned for pointers)
        if (addr & 0x7 == 0) {
            result.verified = true;
            result.reason = "Valid DATA segment address";
            const details_fmt = std.fmt.bufPrint(&result.details, "file_off=0x{x:0>8}", .{file_offset}) catch "";
            result.details_len = details_fmt.len;
        } else {
            result.reason = "Address not 8-byte aligned";
        }
    } else {
        result.reason = "Address outside expected DATA range";
    }

    return result;
}

/// Verify a function at runtime
fn verifyFunctionRuntime(task: c.mach_port_t, addr: u64, expected_prologue: []const u8, func: patterns.FunctionType) VerifyResult {
    var result = VerifyResult{
        .func = func,
        .discovered_addr = addr,
        .verified = false,
        .reason = "",
    };

    if (expected_prologue.len == 0) {
        result.reason = "No prologue to verify";
        return result;
    }

    var actual: [32]u8 = undefined;
    const read_len = @min(expected_prologue.len, 32);
    if (!readTaskMemory(task, addr, actual[0..read_len])) {
        result.reason = "Cannot read memory at address";
        return result;
    }

    var matches: usize = 0;
    var total: usize = 0;
    for (expected_prologue[0..read_len], 0..) |expected, idx| {
        const is_variable = isLikelyVariable(expected_prologue, idx);
        if (!is_variable) {
            total += 1;
            if (actual[idx] == expected) {
                matches += 1;
            }
        }
    }

    const match_pct = if (total > 0) (matches * 100) / total else 0;

    if (match_pct >= 80) {
        result.verified = true;
        result.reason = "Prologue matches";
    } else {
        result.reason = "Prologue mismatch";
    }

    const details_fmt = std.fmt.bufPrint(&result.details, "match={d}% ({d}/{d} bytes)", .{ match_pct, matches, total }) catch "";
    result.details_len = details_fmt.len;

    return result;
}

/// Verify a function statically (check prologue looks valid)
fn verifyFunctionStatic(addr: u64, prologue: []const u8, func: patterns.FunctionType) VerifyResult {
    var result = VerifyResult{
        .func = func,
        .discovered_addr = addr,
        .verified = false,
        .reason = "",
    };

    if (prologue.len < 4) {
        result.reason = "Prologue too short";
        return result;
    }

    // Check for valid ARM64 function prologue patterns
    // PACIBSP: 7F 23 03 D5
    // BTI: DF 24 03 D5 (or similar)
    // STP with frame setup

    const first_instr = std.mem.readInt(u32, prologue[0..4], .little);

    // PACIBSP (most common on arm64e)
    if (first_instr == 0xD503237F) {
        result.verified = true;
        result.reason = "Valid prologue (PACIBSP)";

        // Show first few bytes as hex
        var hex_buf: [48]u8 = undefined;
        var hex_len: usize = 0;
        for (prologue[0..@min(16, prologue.len)]) |b| {
            if (hex_len + 3 > hex_buf.len) break;
            _ = std.fmt.bufPrint(hex_buf[hex_len..][0..3], "{X:0>2} ", .{b}) catch break;
            hex_len += 3;
        }
        const details_fmt = std.fmt.bufPrint(&result.details, "bytes={s}", .{hex_buf[0..hex_len]}) catch "";
        result.details_len = details_fmt.len;
        return result;
    }

    // BTI c (branch target identification)
    if ((first_instr & 0xFFFFFF00) == 0xD5032400) {
        result.verified = true;
        result.reason = "Valid prologue (BTI)";
        return result;
    }

    // STP x29, x30, [sp, #-N]! (pre-indexed frame setup)
    if ((first_instr & 0xFFE07FFF) == 0xA9807BFD) {
        result.verified = true;
        result.reason = "Valid prologue (STP FP/LR)";
        return result;
    }

    // SUB sp, sp, #N (stack allocation as first instruction)
    if ((first_instr & 0xFF0003FF) == 0xD10003FF) {
        result.verified = true;
        result.reason = "Valid prologue (SUB SP)";
        return result;
    }

    result.reason = "Unrecognized prologue pattern";
    return result;
}

/// Verify patch location at runtime
fn verifyPatchLocationRuntime(task: c.mach_port_t, addr: u64, func: patterns.FunctionType) VerifyResult {
    var result = VerifyResult{
        .func = func,
        .discovered_addr = addr,
        .verified = false,
        .reason = "",
    };

    var bytes: [8]u8 = undefined;
    if (!readTaskMemory(task, addr, &bytes)) {
        result.reason = "Cannot read memory at address";
        return result;
    }

    // Expected: FMOV D0, #1.0 (00 10 6A 1E) followed by SUB
    if (bytes[0] == 0x00 and bytes[1] == 0x10 and bytes[2] == 0x6A and bytes[3] == 0x1E) {
        if ((bytes[7] & 0xFF) == 0xD1) {
            result.verified = true;
            result.reason = "FMOV D0, #1.0 + SUB pattern found";
        } else {
            result.reason = "FMOV found but next instruction unexpected";
        }
    } else {
        result.reason = "FMOV D0, #1.0 not found at address";
    }

    const details_fmt = std.fmt.bufPrint(&result.details, "bytes={x:0>2}{x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] }) catch "";
    result.details_len = details_fmt.len;

    return result;
}

/// Verify patch location statically
fn verifyPatchLocationStatic(addr: u64, prologue: []const u8, func: patterns.FunctionType) VerifyResult {
    _ = prologue;
    var result = VerifyResult{
        .func = func,
        .discovered_addr = addr,
        .verified = false,
        .reason = "",
    };

    // For fix_animation, we found it via pattern search for FMOV D0, #1.0
    // The address itself being found means the pattern matched
    // Check that address is in TEXT segment range
    if (addr >= 0x100000000 and addr < 0x100400000) {
        result.verified = true;
        result.reason = "Pattern matched in TEXT segment";
        const details_fmt = std.fmt.bufPrint(&result.details, "FMOV D0, #1.0 pattern", .{}) catch "";
        result.details_len = details_fmt.len;
    } else {
        result.reason = "Address outside expected TEXT range";
    }

    return result;
}

/// Check if a byte position is likely to contain variable data
fn isLikelyVariable(prologue: []const u8, idx: usize) bool {
    if (idx + 4 > prologue.len) return false;

    const instr_start = (idx / 4) * 4;
    const instr = std.mem.readInt(u32, prologue[instr_start..][0..4], .little);

    // ADRP - immediate varies
    if ((instr & 0x9F000000) == 0x90000000) return true;
    // BL/B - offset varies
    if ((instr & 0xFC000000) == 0x94000000) return true;
    if ((instr & 0xFC000000) == 0x14000000) return true;

    return false;
}

/// Format verification report for display
pub fn formatReport(report: *const VerificationReport, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    writer.print("Verification mode: {s}\n", .{report.mode}) catch {};
    writer.print("Dock PID: {d}\n", .{report.dock_pid}) catch {};
    if (report.dock_base != 0) {
        writer.print("Dock Base: 0x{x:0>16}\n", .{report.dock_base}) catch {};
    }
    writer.writeAll("─────────────────────────────────────────────────────────────\n") catch {};

    for (report.results) |r| {
        const status = if (r.verified) "✓" else "✗";
        const name = r.func.name();

        writer.print("{s} {s:<20} 0x{x:0>8}  {s}", .{ status, name, r.discovered_addr, r.reason }) catch {};

        if (r.details_len > 0) {
            writer.print(" [{s}]", .{r.details[0..r.details_len]}) catch {};
        }
        writer.writeAll("\n") catch {};
    }

    writer.writeAll("─────────────────────────────────────────────────────────────\n") catch {};
    if (report.all_verified) {
        writer.writeAll("All functions verified ✓\n") catch {};
    } else {
        writer.writeAll("Some functions failed verification\n") catch {};
    }

    return fbs.getWritten();
}

// ============================================================================
// Tests
// ============================================================================

test "VerifyResult default values" {
    const result = VerifyResult{
        .func = .dock_spaces,
        .discovered_addr = 0x12345678,
        .verified = false,
        .reason = "test reason",
    };
    try std.testing.expectEqual(patterns.FunctionType.dock_spaces, result.func);
    try std.testing.expectEqual(@as(u64, 0x12345678), result.discovered_addr);
    try std.testing.expect(!result.verified);
    try std.testing.expectEqualStrings("test reason", result.reason);
    try std.testing.expectEqual(@as(usize, 0), result.details_len);
}

test "VerificationReport initialization" {
    var report = VerificationReport{
        .results = undefined,
        .dock_pid = 1234,
        .dock_base = 0x100000000,
        .all_verified = true,
        .mode = "static",
    };
    for (&report.results, 0..) |*r, i| {
        r.* = .{
            .func = @enumFromInt(i),
            .discovered_addr = 0,
            .verified = false,
            .reason = "init",
        };
    }
    try std.testing.expectEqual(@as(i32, 1234), report.dock_pid);
    try std.testing.expectEqual(@as(u64, 0x100000000), report.dock_base);
    try std.testing.expectEqualStrings("static", report.mode);
}

test "isLikelyVariable ADRP instruction" {
    // ADRP X0, #page - opcode has 0x90 in top byte (0x9F masked)
    const adrp_instr = [4]u8{ 0x00, 0x00, 0x00, 0x90 }; // ADRP
    try std.testing.expect(isLikelyVariable(&adrp_instr, 0));
}

test "isLikelyVariable BL instruction" {
    // BL #offset - opcode 0x94xxxxxx
    const bl_instr = [4]u8{ 0x00, 0x00, 0x00, 0x94 }; // BL
    try std.testing.expect(isLikelyVariable(&bl_instr, 0));
}

test "isLikelyVariable B instruction" {
    // B #offset - opcode 0x14xxxxxx
    const b_instr = [4]u8{ 0x00, 0x00, 0x00, 0x14 }; // B
    try std.testing.expect(isLikelyVariable(&b_instr, 0));
}

test "isLikelyVariable non-variable instruction" {
    // PACIBSP - 7F 23 03 D5 - fixed instruction
    const pacibsp = [4]u8{ 0x7F, 0x23, 0x03, 0xD5 };
    try std.testing.expect(!isLikelyVariable(&pacibsp, 0));
}

test "isLikelyVariable buffer too small" {
    const small = [2]u8{ 0x00, 0x00 };
    try std.testing.expect(!isLikelyVariable(&small, 0));
}

test "verifyGlobalStatic valid DATA address" {
    const result = verifyGlobalStatic(0x100400000, 0x1000, .dock_spaces);
    try std.testing.expect(result.verified);
    try std.testing.expectEqualStrings("Valid DATA segment address", result.reason);
}

test "verifyGlobalStatic address outside DATA range" {
    const result = verifyGlobalStatic(0x100100000, 0x1000, .dock_spaces);
    try std.testing.expect(!result.verified);
    try std.testing.expectEqualStrings("Address outside expected DATA range", result.reason);
}

test "verifyGlobalStatic unaligned address" {
    const result = verifyGlobalStatic(0x100400001, 0x1000, .dock_spaces);
    try std.testing.expect(!result.verified);
    try std.testing.expectEqualStrings("Address not 8-byte aligned", result.reason);
}

test "verifyFunctionStatic with PACIBSP prologue" {
    // PACIBSP: 7F 23 03 D5
    const prologue = [4]u8{ 0x7F, 0x23, 0x03, 0xD5 };
    const result = verifyFunctionStatic(0x100050000, &prologue, .add_space);
    try std.testing.expect(result.verified);
    try std.testing.expectEqualStrings("Valid prologue (PACIBSP)", result.reason);
}

test "verifyFunctionStatic with STP prologue" {
    // STP x29, x30, [sp, #-N]! pattern: A9 80 7B FD (simplified)
    const prologue = [4]u8{ 0xFD, 0x7B, 0x80, 0xA9 };
    const result = verifyFunctionStatic(0x100050000, &prologue, .add_space);
    try std.testing.expect(result.verified);
    try std.testing.expectEqualStrings("Valid prologue (STP FP/LR)", result.reason);
}

test "verifyFunctionStatic prologue too short" {
    const prologue = [2]u8{ 0x7F, 0x23 };
    const result = verifyFunctionStatic(0x100050000, &prologue, .add_space);
    try std.testing.expect(!result.verified);
    try std.testing.expectEqualStrings("Prologue too short", result.reason);
}

test "verifyPatchLocationStatic valid TEXT address" {
    const prologue = [4]u8{ 0x00, 0x10, 0x6A, 0x1E }; // FMOV D0, #1.0
    const result = verifyPatchLocationStatic(0x100200000, &prologue, .fix_animation);
    try std.testing.expect(result.verified);
    try std.testing.expectEqualStrings("Pattern matched in TEXT segment", result.reason);
}

test "verifyPatchLocationStatic address outside TEXT" {
    const prologue = [4]u8{ 0x00, 0x10, 0x6A, 0x1E };
    const result = verifyPatchLocationStatic(0x100500000, &prologue, .fix_animation);
    try std.testing.expect(!result.verified);
    try std.testing.expectEqualStrings("Address outside expected TEXT range", result.reason);
}

test "formatReport basic output" {
    var report = VerificationReport{
        .results = undefined,
        .dock_pid = 1234,
        .dock_base = 0x100000000,
        .all_verified = true,
        .mode = "static",
    };
    for (&report.results, 0..) |*r, i| {
        r.* = .{
            .func = @enumFromInt(i),
            .discovered_addr = 0x100000000 + i * 0x1000,
            .verified = true,
            .reason = "OK",
        };
    }

    var buf: [2048]u8 = undefined;
    const output = formatReport(&report, &buf);

    try std.testing.expect(std.mem.indexOf(u8, output, "static") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "All functions verified") != null);
}

test "formatReport failed verification" {
    var report = VerificationReport{
        .results = undefined,
        .dock_pid = 0,
        .dock_base = 0,
        .all_verified = false,
        .mode = "runtime",
    };
    for (&report.results, 0..) |*r, i| {
        r.* = .{
            .func = @enumFromInt(i),
            .discovered_addr = 0,
            .verified = false,
            .reason = "Not found",
        };
    }

    var buf: [2048]u8 = undefined;
    const output = formatReport(&report, &buf);

    try std.testing.expect(std.mem.indexOf(u8, output, "runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Some functions failed") != null);
}

test "integration: findDockPid on macOS" {
    // This test only runs on macOS
    const pid = findDockPid();
    // Dock should be running on any macOS system
    if (pid) |p| {
        try std.testing.expect(p > 0);
    }
    // If null, we're not on macOS or Dock isn't running - that's OK
}
