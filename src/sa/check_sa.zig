const std = @import("std");
const sa_extractor = @import("extractor.zig");

// Minimal check-sa executable for fast development iteration
pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Default to Dock binary
    const binary_path = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";

    std.debug.print("SA Pattern Analysis\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n\n", .{});

    // Print binary path
    std.debug.print("Binary: {s}\n", .{binary_path});

    // Get OS version
    const os_version = sa_extractor.getCurrentOSVersion() catch {
        std.debug.print("error: cannot determine macOS version\n", .{});
        return 1;
    };
    std.debug.print("macOS:  {}.{}.{}\n\n", .{ os_version.major, os_version.minor, os_version.patch });

    // Read binary
    const binary_data = std.fs.cwd().readFileAlloc(allocator, binary_path, 32 * 1024 * 1024) catch |err| {
        std.debug.print("error: cannot read binary: {}\n", .{err});
        return 1;
    };
    defer allocator.free(binary_data);

    // Extract arm64 slice
    const arm64_data = sa_extractor.extractArm64Slice(binary_data) orelse {
        std.debug.print("error: no arm64 slice found in binary\n", .{});
        return 1;
    };

    std.debug.print("Size:   {} bytes (arm64 slice: {} bytes)\n\n", .{ binary_data.len, arm64_data.len });

    // Run discovery
    const result = sa_extractor.discoverFunctions(allocator, arm64_data) catch |err| {
        std.debug.print("error: discovery failed: {}\n", .{err});
        return 1;
    };

    // Print diagnostic report
    var report_buf: [8192]u8 = undefined;
    const report = result.toDiagnosticReport(&report_buf);
    std.debug.print("{s}", .{report});

    // Return success only if all functions found
    return if (result.foundCount() == 7) 0 else 1;
}
