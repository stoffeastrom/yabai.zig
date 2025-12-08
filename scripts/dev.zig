const std = @import("std");
const posix = std.posix;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get path to binaries
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        std.debug.print("error: cannot get executable path\n", .{});
        return 1;
    };
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    var yabai_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const yabai_path = std.fmt.bufPrint(&yabai_path_buf, "{s}/yabai.zig", .{exe_dir}) catch {
        std.debug.print("error: path too long\n", .{});
        return 1;
    };

    const user = std.posix.getenv("USER") orelse "unknown";

    // Check for --load-sa flag
    var load_sa = false;
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--load-sa")) {
            load_sa = true;
            break;
        }
    }

    if (load_sa) {
        std.debug.print("Restarting Dock and loading SA...\n", .{});

        var killall = std.process.Child.init(&.{ "/usr/bin/killall", "Dock" }, allocator);
        killall.spawn() catch {};
        _ = killall.wait() catch {};
        std.Thread.sleep(2 * std.time.ns_per_s);

        std.debug.print("Loading SA...\n", .{});

        // Try passwordless sudo first (if user set up sudoers)
        var sudo_child = std.process.Child.init(&.{ "/usr/bin/sudo", "-n", yabai_path, "--load-sa" }, allocator);
        sudo_child.stderr_behavior = .Ignore;
        sudo_child.stdout_behavior = .Ignore;
        sudo_child.spawn() catch {
            std.debug.print("error: failed to spawn sudo\n", .{});
            return 1;
        };

        const sudo_term = sudo_child.wait() catch {
            std.debug.print("error: sudo wait failed\n", .{});
            return 1;
        };

        if (sudo_term.Exited == 0) {
            std.debug.print("SA loaded\n", .{});
        } else {
            // Passwordless sudo failed, use GUI prompt
            std.debug.print("Requesting authorization (add to sudoers to skip this)...\n", .{});

            var script_buf: [1024]u8 = undefined;
            const script = std.fmt.bufPrint(&script_buf, "do shell script \"{s} --load-sa\" with administrator privileges", .{yabai_path}) catch {
                std.debug.print("error: script too long\n", .{});
                return 1;
            };

            var auth_child = std.process.Child.init(&.{ "/usr/bin/osascript", "-e", script }, allocator);
            auth_child.spawn() catch {
                std.debug.print("error: failed to request auth\n", .{});
                return 1;
            };

            const auth_term = auth_child.wait() catch {
                std.debug.print("error: auth wait failed\n", .{});
                return 1;
            };

            if (auth_term.Exited != 0) {
                std.debug.print("SA loading cancelled - continuing without SA\n", .{});
            } else {
                std.debug.print("SA loaded\n", .{});
            }
        }
    }

    // Clean up stale lock files
    var lock_path_buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "/tmp/yabai.zig_{s}.lock", .{user}) catch "/tmp/yabai.zig.lock";
    std.fs.cwd().deleteFile(lock_path) catch {};

    // Ignore SIGINT in parent - only child should receive it
    const act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);

    // Collect args to pass through (excluding --load-sa)
    var args_list = std.ArrayListUnmanaged([]const u8){};
    defer args_list.deinit(allocator);

    try args_list.append(allocator, yabai_path);

    for (args[1..]) |arg| {
        if (!std.mem.eql(u8, arg, "--load-sa")) {
            try args_list.append(allocator, arg);
        }
    }

    // Run yabai.zig
    std.debug.print("Starting yabai.zig... (Ctrl+C to stop)\n\n", .{});

    var child = std.process.Child.init(args_list.items, allocator);
    child.spawn() catch |err| {
        std.debug.print("error: failed to start yabai.zig: {}\n", .{err});
        return 1;
    };

    const term = child.wait() catch |err| {
        std.debug.print("error: wait failed: {}\n", .{err});
        return 1;
    };

    std.debug.print("\nyabai.zig stopped\n", .{});

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}
