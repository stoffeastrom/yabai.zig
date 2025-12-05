const std = @import("std");
const posix = std.posix;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Ignore SIGINT in parent - only child should receive it
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);

    // Stop yabai and skhd
    stopService("yabai");
    stopService("skhd");

    // Clean up stale lock files
    const user = std.posix.getenv("USER") orelse "unknown";
    var lock_path_buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "/tmp/yabai.zig_{s}.lock", .{user}) catch "/tmp/yabai.zig.lock";
    std.fs.cwd().deleteFile(lock_path) catch {};

    // Get path to yabai.zig (same directory as this binary)
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        std.debug.print("error: cannot get executable path\n", .{});
        return 1;
    };
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    var yabai_zig_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const yabai_zig_path = std.fmt.bufPrint(&yabai_zig_path_buf, "{s}/yabai.zig", .{exe_dir}) catch {
        std.debug.print("error: path too long\n", .{});
        return 1;
    };

    // Collect args to pass through
    var args_list = std.ArrayList([]const u8){};
    defer args_list.deinit(allocator);

    try args_list.append(allocator, yabai_zig_path);

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip argv[0]
    for (args[1..]) |arg| {
        try args_list.append(allocator, arg);
    }

    // Run yabai.zig
    std.debug.print("Starting yabai.zig (Ctrl+C to stop and restart services)\n", .{});

    var child = std.process.Child.init(args_list.items, allocator);
    child.spawn() catch |err| {
        std.debug.print("error: failed to start yabai.zig: {}\n", .{err});
        startService("yabai");
        startService("skhd");
        return 1;
    };

    const term = child.wait() catch |err| {
        std.debug.print("error: wait failed: {}\n", .{err});
        startService("yabai");
        startService("skhd");
        return 1;
    };

    // Restart services
    std.debug.print("\nRestarting services...\n", .{});
    startService("yabai");
    startService("skhd");

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn run(argv: []const []const u8) u8 {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 1;
    const term = child.wait() catch return 1;
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn isRunning(name: []const u8) bool {
    var child = std.process.Child.init(&.{ "pgrep", "-x", name }, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn stopService(name: []const u8) void {
    std.debug.print("Stopping {s}...\n", .{name});
    _ = run(&.{ name, "--stop-service" });

    if (isRunning(name)) {
        std.debug.print("warning: {s} still running, killing...\n", .{name});
        _ = run(&.{ "pkill", "-x", name });
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn startService(name: []const u8) void {
    std.debug.print("Starting {s}...\n", .{name});
    _ = run(&.{ name, "--start-service" });
}
