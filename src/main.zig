const std = @import("std");
const c = @import("platform/c.zig");
const skylight = @import("platform/skylight.zig");
const Daemon = @import("Daemon.zig").Daemon;
// Core types
pub const geometry = @import("core/geometry.zig");
pub const Window = @import("core/Window.zig");
pub const Application = @import("core/Application.zig");
pub const Space = @import("core/Space.zig");
pub const Display = @import("core/Display.zig");
pub const View = @import("core/View.zig");
pub const Layout = @import("core/Layout.zig");
pub const Rule = @import("core/Rule.zig");
pub const Animation = @import("core/Animation.zig");

// Config
pub const Config = @import("config/Config.zig");
pub const Hotload = @import("config/Hotload.zig");

// Events
pub const Event = @import("events/Event.zig");
pub const EventLoop = @import("events/EventLoop.zig");
pub const Mouse = @import("events/Mouse.zig");
pub const Signal = @import("events/Signal.zig");
pub const Store = @import("events/Store.zig");
pub const Emulator = @import("events/Emulator.zig");

// State
pub const Windows = @import("state/Windows.zig");
pub const Spaces = @import("state/Spaces.zig");
pub const Displays = @import("state/Displays.zig");
pub const Apps = @import("state/Apps.zig");

// Platform layer
pub const ax = @import("platform/accessibility.zig");
pub const runloop = @import("platform/runloop.zig");
pub const workspace = @import("platform/workspace.zig");

// IPC
pub const Server = @import("ipc/Server.zig");
pub const Message = @import("ipc/Message.zig");
pub const CommandHandler = @import("ipc/CommandHandler.zig");
pub const Response = @import("ipc/Response.zig");

// SA pattern extraction (used for auto-discovery at daemon startup)
pub const sa_extractor = @import("sa/extractor.zig");
pub const sa_injector = @import("sa/injector.zig");

const log = std.log.scoped(.yabai);

// File logging for debugging
var log_file: ?std.fs.File = null;
var log_buf: [4096]u8 = undefined;

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
};

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    // Format to buffer then write
    var fbs = std.io.fixedBufferStream(&log_buf);
    const w = fbs.writer();
    nosuspend w.print(prefix ++ format ++ "\n", args) catch return;
    const msg = fbs.getWritten();

    // Write to stderr
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};

    // Also write to log file if open
    if (log_file) |f| {
        _ = f.write(msg) catch {};
    }
}

pub const Version = struct {
    pub const major: u32 = 0;
    pub const minor: u32 = 1;
    pub const patch: u32 = 0;

    pub fn string() []const u8 {
        return std.fmt.comptimePrint("yabai.zig-v{d}.{d}.{d}", .{ major, minor, patch });
    }
};

pub const MAXLEN = 512;

const Args = struct {
    verbose: bool = false,
    config_file: [4096]u8 = undefined,
    timeout_ms: ?u64 = null,
    record_path: ?[]const u8 = null,
};

var g: Args = .{};

fn getStdout() std.fs.File {
    return .{ .handle = std.posix.STDOUT_FILENO };
}

fn getStderr() std.fs.File {
    return .{ .handle = std.posix.STDERR_FILENO };
}

fn printUsage() void {
    getStdout().writeAll(
        \\Usage: yabai.zig [option]
        \\
        \\Options:
        \\    --install-cert         Create and install code signing certificate.
        \\    --sign                 Sign the yabai.zig binary with certificate.
        \\    --install-service      Write launchd service file to disk.
        \\    --uninstall-service    Remove launchd service file from disk.
        \\    --start-service        Enable, load, and start the launchd service.
        \\    --restart-service      Attempts to restart the service instance.
        \\    --stop-service         Stops a running instance of the service.
        \\    --load-sa              Install and load scripting addition (requires sudo).
        \\    --unload-sa            Unload and remove scripting addition (requires sudo).
        \\    --reload-sa            Kill Dock and re-inject SA (requires sudo, for development).
        \\    --kill-dock            Kill Dock to reload scripting addition.
        \\    --install-sudoers      Add sudoers entry for passwordless SA operations.
        \\    --message, -m <msg>    Send message to a running instance of yabai.zig.
        \\    --config, -c <config>  Use the specified configuration file.
        \\    --timeout <ms>         Exit after specified milliseconds (for testing).
        \\    --record <path>        Record events to file for replay testing.
        \\    --debug                Skip accessibility check (for development).
        \\    --verbose, -V          Output debug information to stdout.
        \\    --check-sa [path]      Analyze binary for SA patterns (default: Dock).
        \\    --version, -v          Print version to stdout and exit.
        \\    --help, -h             Print options to stdout and exit.
        \\
        \\See https://github.com/stoffeastrom/yabai.zig for more information.
        \\
    ) catch {};
}

fn printVersion() void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}\n", .{Version.string()}) catch return;
    getStdout().writeAll(msg) catch {};
}

/// Send a message to a running yabai.zig instance
fn sendMessage(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const stdout = getStdout();
    const stderr = getStderr();

    if (args.len == 0) {
        stderr.writeAll("yabai.zig-msg: no arguments given! abort..\n") catch {};
        return 1;
    }

    const user = std.posix.getenv("USER") orelse {
        stderr.writeAll("yabai.zig-msg: 'env USER' not set! abort..\n") catch {};
        return 1;
    };

    // Build socket path
    var socket_path_buf: [MAXLEN]u8 = undefined;
    const socket_path = std.fmt.bufPrint(&socket_path_buf, "/tmp/yabai.zig_{s}.socket", .{user}) catch return 1;

    // Calculate message length
    var message_length: usize = args.len; // null terminators
    for (args) |arg| {
        message_length += arg.len;
    }
    message_length += 1; // final null

    // Build message: length prefix + args
    var message = try allocator.alloc(u8, @sizeOf(i32) + message_length);
    defer allocator.free(message);

    // Write length prefix
    const len_i32: i32 = @intCast(message_length);
    @memcpy(message[0..@sizeOf(i32)], std.mem.asBytes(&len_i32));

    // Write args with null terminators
    var offset: usize = @sizeOf(i32);
    for (args) |arg| {
        @memcpy(message[offset..][0..arg.len], arg);
        offset += arg.len;
        message[offset] = 0;
        offset += 1;
    }
    message[offset] = 0;

    // Connect to socket
    const sockfd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
        stderr.writeAll("yabai.zig-msg: failed to open socket..\n") catch {};
        return 1;
    };
    defer std.posix.close(sockfd);

    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    std.posix.connect(sockfd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        stderr.writeAll("yabai.zig-msg: failed to connect to socket..\n") catch {};
        return 1;
    };

    // Send message
    _ = std.posix.send(sockfd, message, 0) catch {
        stderr.writeAll("yabai.zig-msg: failed to send data..\n") catch {};
        return 1;
    };

    std.posix.shutdown(sockfd, .send) catch {};

    // Read response
    var result: u8 = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(sockfd, &buf) catch break;
        if (bytes_read == 0) break;

        const response = buf[0..bytes_read];
        if (response.len > 0 and response[0] == 0x07) { // FAILURE_MESSAGE
            result = 1;
            stderr.writeAll(response[1..]) catch {};
        } else {
            stdout.writeAll(response) catch {};
        }
    }

    return result;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        // Start daemon mode
        return startDaemon(false);
    }

    const opt = args[1];

    // Help
    if (std.mem.eql(u8, opt, "-h") or std.mem.eql(u8, opt, "--help")) {
        printUsage();
        return 0;
    }

    // Version
    if (std.mem.eql(u8, opt, "-v") or std.mem.eql(u8, opt, "--version")) {
        printVersion();
        return 0;
    }

    // Message
    if (std.mem.eql(u8, opt, "-m") or std.mem.eql(u8, opt, "--message")) {
        return sendMessage(allocator, args[2..]);
    }

    // Direct domain commands: space, window, display, query, config
    if (std.mem.eql(u8, opt, "space") or
        std.mem.eql(u8, opt, "window") or
        std.mem.eql(u8, opt, "display") or
        std.mem.eql(u8, opt, "query") or
        std.mem.eql(u8, opt, "config"))
    {
        return sendMessage(allocator, args[1..]);
    }

    // Service operations
    if (std.mem.eql(u8, opt, "--install-service")) {
        return installService();
    }
    if (std.mem.eql(u8, opt, "--uninstall-service")) {
        return uninstallService();
    }
    if (std.mem.eql(u8, opt, "--start-service")) {
        return startService();
    }
    if (std.mem.eql(u8, opt, "--restart-service")) {
        return restartService();
    }
    if (std.mem.eql(u8, opt, "--stop-service")) {
        return stopService();
    }

    // Certificate operations
    if (std.mem.eql(u8, opt, "--install-cert")) {
        return installCert();
    }
    if (std.mem.eql(u8, opt, "--sign")) {
        return signBinary();
    }

    // SA analysis
    if (std.mem.eql(u8, opt, "--check-sa")) {
        const binary_path = if (args.len > 2) args[2] else "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";
        return checkSA(allocator, binary_path);
    }

    // SA loading (requires root)
    if (std.mem.eql(u8, opt, "--load-sa")) {
        return loadSA();
    }
    if (std.mem.eql(u8, opt, "--unload-sa")) {
        return unloadSA();
    }
    if (std.mem.eql(u8, opt, "--reload-sa")) {
        return reloadSA();
    }

    // Sudoers setup for passwordless SA loading
    if (std.mem.eql(u8, opt, "--install-sudoers")) {
        return installSudoers();
    }

    // Kill Dock (convenience for SA reload during development)
    if (std.mem.eql(u8, opt, "--kill-dock")) {
        return killDock();
    }

    // Parse remaining options for daemon mode
    var i: usize = 1;
    var skip_checks = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--verbose")) {
            g.verbose = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            skip_checks = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                getStderr().writeAll("yabai.zig: option '--timeout' requires an argument!\n") catch {};
                return 1;
            }
            g.timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                getStderr().writeAll("yabai.zig: invalid timeout value!\n") catch {};
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--record")) {
            i += 1;
            if (i >= args.len) {
                getStderr().writeAll("yabai.zig: option '--record' requires a path!\n") catch {};
                return 1;
            }
            g.record_path = args[i];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) {
                getStderr().writeAll("yabai.zig: option '-c|--config' requires an argument!\n") catch {};
                return 1;
            }
            // Store config path in globals
            const config_arg = args[i];
            if (config_arg.len >= g.config_file.len) {
                getStderr().writeAll("yabai.zig: config path too long!\n") catch {};
                return 1;
            }
            @memcpy(g.config_file[0..config_arg.len], config_arg);
            g.config_file[config_arg.len] = 0;
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "yabai.zig: '{s}' is not a valid option!\n", .{arg}) catch return 1;
            getStderr().writeAll(msg) catch {};
            return 1;
        }
    }

    // --timeout requires --debug
    if (g.timeout_ms != null and !skip_checks) {
        getStderr().writeAll("yabai.zig: --timeout requires --debug\n") catch {};
        return 1;
    }

    return startDaemon(skip_checks);
}

// =============================================================================
// Service management
// =============================================================================

const SERVICE_NAME = "com.stoffeastrom.yabai.zig";
const CERT_NAME = "yabai.zig-cert";

fn writePlist() !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const user = std.posix.getenv("USER") orelse return error.NoUser;
    const path_env = std.posix.getenv("PATH") orelse "/usr/bin:/bin";

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch return error.NoExePath;

    // Ensure LaunchAgents directory exists
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/Library/LaunchAgents", .{home}) catch return error.PathTooLong;
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var plist_path_buf: [512]u8 = undefined;
    const plist_path = std.fmt.bufPrint(&plist_path_buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, SERVICE_NAME }) catch return error.PathTooLong;

    const file = std.fs.createFileAbsolute(plist_path, .{}) catch return error.CreateFailed;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>PATH</key>
        \\        <string>{s}</string>
        \\    </dict>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\        <key>SuccessfulExit</key>
        \\        <false/>
        \\        <key>Crashed</key>
        \\        <true/>
        \\    </dict>
        \\    <key>StandardOutPath</key>
        \\    <string>/tmp/yabai.zig_{s}.out.log</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>/tmp/yabai.zig_{s}.err.log</string>
        \\    <key>ProcessType</key>
        \\    <string>Interactive</string>
        \\    <key>Nice</key>
        \\    <integer>-20</integer>
        \\</dict>
        \\</plist>
        \\
    , .{ SERVICE_NAME, exe_path, path_env, user, user }) catch return error.WriteFailed;

    file.writeAll(fbs.getWritten()) catch return error.WriteFailed;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn runCmd(argv: []const []const u8, suppress: bool) u8 {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    if (suppress) {
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    }
    child.spawn() catch return 1;
    const term = child.wait() catch return 1;
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn installService() u8 {
    const home = std.posix.getenv("HOME") orelse {
        getStderr().writeAll("yabai.zig: HOME not set\n") catch {};
        return 1;
    };

    var plist_path_buf: [512]u8 = undefined;
    const plist_path = std.fmt.bufPrint(&plist_path_buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, SERVICE_NAME }) catch {
        getStderr().writeAll("yabai.zig: path too long\n") catch {};
        return 1;
    };

    if (fileExists(plist_path)) {
        getStderr().writeAll("yabai.zig: service already installed\n") catch {};
        return 1;
    }

    writePlist() catch {
        getStderr().writeAll("yabai.zig: failed to write plist\n") catch {};
        return 1;
    };

    getStdout().writeAll("yabai.zig: service installed\n") catch {};
    return 0;
}

fn uninstallService() u8 {
    const home = std.posix.getenv("HOME") orelse {
        getStderr().writeAll("yabai.zig: HOME not set\n") catch {};
        return 1;
    };

    var plist_path_buf: [512]u8 = undefined;
    const plist_path = std.fmt.bufPrint(&plist_path_buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, SERVICE_NAME }) catch {
        return 1;
    };

    if (!fileExists(plist_path)) {
        getStderr().writeAll("yabai.zig: service not installed\n") catch {};
        return 1;
    }

    std.fs.deleteFileAbsolute(plist_path) catch {
        getStderr().writeAll("yabai.zig: failed to remove plist\n") catch {};
        return 1;
    };

    getStdout().writeAll("yabai.zig: service uninstalled\n") catch {};
    return 0;
}

fn startService() u8 {
    const home = std.posix.getenv("HOME") orelse {
        getStderr().writeAll("yabai.zig: HOME not set\n") catch {};
        return 1;
    };

    var plist_path_buf: [512]u8 = undefined;
    const plist_path = std.fmt.bufPrint(&plist_path_buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, SERVICE_NAME }) catch return 1;

    if (!fileExists(plist_path)) {
        getStderr().writeAll("yabai.zig: service not installed, installing...\n") catch {};
        writePlist() catch {
            getStderr().writeAll("yabai.zig: failed to write plist\n") catch {};
            return 1;
        };
    }

    var service_target_buf: [256]u8 = undefined;
    const uid = c.c.getuid();
    const service_target = std.fmt.bufPrint(&service_target_buf, "gui/{d}/{s}", .{ uid, SERVICE_NAME }) catch return 1;

    var domain_target_buf: [64]u8 = undefined;
    const domain_target = std.fmt.bufPrint(&domain_target_buf, "gui/{d}", .{uid}) catch return 1;

    // Check if already bootstrapped
    const is_bootstrapped = runCmd(&.{ "/bin/launchctl", "print", service_target }, true) == 0;

    if (!is_bootstrapped) {
        // Not bootstrapped - enable and bootstrap
        _ = runCmd(&.{ "/bin/launchctl", "enable", service_target }, true);
        return runCmd(&.{ "/bin/launchctl", "bootstrap", domain_target, plist_path }, false);
    } else {
        // Already bootstrapped - kickstart
        return runCmd(&.{ "/bin/launchctl", "kickstart", service_target }, false);
    }
}

fn restartService() u8 {
    var service_target_buf: [256]u8 = undefined;
    const uid = c.c.getuid();
    const service_target = std.fmt.bufPrint(&service_target_buf, "gui/{d}/{s}", .{ uid, SERVICE_NAME }) catch return 1;

    return runCmd(&.{ "/bin/launchctl", "kickstart", "-k", service_target }, false);
}

fn stopService() u8 {
    const home = std.posix.getenv("HOME") orelse {
        getStderr().writeAll("yabai.zig: HOME not set\n") catch {};
        return 1;
    };

    var plist_path_buf: [512]u8 = undefined;
    const plist_path = std.fmt.bufPrint(&plist_path_buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, SERVICE_NAME }) catch return 1;

    if (!fileExists(plist_path)) {
        getStderr().writeAll("yabai.zig: service not installed\n") catch {};
        return 1;
    }

    var service_target_buf: [256]u8 = undefined;
    const uid = c.c.getuid();
    const service_target = std.fmt.bufPrint(&service_target_buf, "gui/{d}/{s}", .{ uid, SERVICE_NAME }) catch return 1;

    var domain_target_buf: [64]u8 = undefined;
    const domain_target = std.fmt.bufPrint(&domain_target_buf, "gui/{d}", .{uid}) catch return 1;

    // Check if bootstrapped
    const is_bootstrapped = runCmd(&.{ "/bin/launchctl", "print", service_target }, true) == 0;

    if (!is_bootstrapped) {
        // Not bootstrapped - just kill
        return runCmd(&.{ "/bin/launchctl", "kill", "SIGTERM", service_target }, false);
    } else {
        // Bootstrapped - bootout and disable
        _ = runCmd(&.{ "/bin/launchctl", "bootout", domain_target, plist_path }, false);
        return runCmd(&.{ "/bin/launchctl", "disable", service_target }, false);
    }
}

// =============================================================================
// Certificate management
// =============================================================================

fn installCert() u8 {
    const stderr = getStderr();
    const stdout = getStdout();

    // Check if cert already exists
    var check_child = std.process.Child.init(&.{ "/usr/bin/security", "find-identity", "-v", "-p", "codesigning" }, std.heap.page_allocator);
    check_child.stdout_behavior = .Pipe;
    check_child.stderr_behavior = .Ignore;
    check_child.spawn() catch {
        stderr.writeAll("yabai.zig: failed to check existing certificates\n") catch {};
        return 1;
    };

    var output_buf: [4096]u8 = undefined;
    const output_len = check_child.stdout.?.readAll(&output_buf) catch 0;
    _ = check_child.wait() catch {};

    if (std.mem.indexOf(u8, output_buf[0..output_len], CERT_NAME) != null) {
        stdout.writeAll("yabai.zig: certificate already installed\n") catch {};
        return 0;
    }

    // Create certificate config
    const cert_cfg =
        \\[ req ]
        \\default_bits = 2048
        \\prompt = no
        \\default_md = sha256
        \\distinguished_name = dn
        \\x509_extensions = v3_code
        \\
        \\[ dn ]
        \\CN = yabai.zig-cert
        \\O = yabai.zig
        \\
        \\[ v3_code ]
        \\keyUsage = critical, digitalSignature
        \\extendedKeyUsage = critical, codeSigning
    ;

    // Write config file
    const cfg_path = "/tmp/yabai.zig.cert.cfg";
    const key_path = "/tmp/yabai.zig.key";
    const crt_path = "/tmp/yabai.zig.crt";
    const p12_path = "/tmp/yabai.zig.p12";

    if (std.fs.createFileAbsolute(cfg_path, .{})) |f| {
        f.writeAll(cert_cfg) catch {};
        f.close();
    } else |_| {
        stderr.writeAll("yabai.zig: failed to write cert config\n") catch {};
        return 1;
    }

    // Generate key and certificate
    stdout.writeAll("yabai.zig: generating certificate...\n") catch {};
    if (runCmd(&.{
        "/usr/bin/openssl", "req",    "-x509",   "-newkey", "rsa:2048",
        "-keyout",          key_path, "-out",    crt_path,  "-days",
        "3650",             "-nodes", "-config", cfg_path,
    }, true) != 0) {
        stderr.writeAll("yabai.zig: failed to generate certificate\n") catch {};
        return 1;
    }

    // Create p12 bundle (legacy format for macOS compatibility)
    if (runCmd(&.{
        "/usr/bin/openssl", "pkcs12",    "-legacy",
        "-export",          "-out",      p12_path,
        "-inkey",           key_path,    "-in",
        crt_path,           "-password", "pass:yabai.zig",
    }, true) != 0) {
        stderr.writeAll("yabai.zig: failed to create p12 bundle\n") catch {};
        return 1;
    }

    // Import to keychain
    stdout.writeAll("yabai.zig: importing to keychain...\n") catch {};
    const home = std.posix.getenv("HOME") orelse {
        stderr.writeAll("yabai.zig: HOME not set\n") catch {};
        return 1;
    };

    var keychain_buf: [512]u8 = undefined;
    const keychain = std.fmt.bufPrint(&keychain_buf, "{s}/Library/Keychains/login.keychain-db", .{home}) catch return 1;

    if (runCmd(&.{
        "/usr/bin/security", "import", p12_path,
        "-k",                keychain, "-P",
        "yabai.zig",         "-T",     "/usr/bin/codesign",
    }, false) != 0) {
        stderr.writeAll("yabai.zig: failed to import certificate\n") catch {};
        return 1;
    }

    // Trust the certificate
    stdout.writeAll("yabai.zig: trusting certificate...\n") catch {};
    if (runCmd(&.{
        "/usr/bin/security", "add-trusted-cert",
        "-d",                "-r",
        "trustRoot",         "-k",
        keychain,            crt_path,
    }, false) != 0) {
        stderr.writeAll("yabai.zig: failed to trust certificate (may need manual approval)\n") catch {};
    }

    // Cleanup temp files
    std.fs.deleteFileAbsolute(cfg_path) catch {};
    std.fs.deleteFileAbsolute(key_path) catch {};
    std.fs.deleteFileAbsolute(crt_path) catch {};
    std.fs.deleteFileAbsolute(p12_path) catch {};

    stdout.writeAll("yabai.zig: certificate installed successfully\n") catch {};
    return 0;
}

fn signBinary() u8 {
    const stderr = getStderr();
    const stdout = getStdout();

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        stderr.writeAll("yabai.zig: failed to get executable path\n") catch {};
        return 1;
    };

    // Check if certificate exists
    var check_child = std.process.Child.init(&.{ "/usr/bin/security", "find-identity", "-v", "-p", "codesigning" }, std.heap.page_allocator);
    check_child.stdout_behavior = .Pipe;
    check_child.stderr_behavior = .Ignore;
    check_child.spawn() catch {
        stderr.writeAll("yabai.zig: failed to check certificates\n") catch {};
        return 1;
    };

    var output_buf: [4096]u8 = undefined;
    const output_len = check_child.stdout.?.readAll(&output_buf) catch 0;
    _ = check_child.wait() catch {};

    if (std.mem.indexOf(u8, output_buf[0..output_len], CERT_NAME) == null) {
        stderr.writeAll("yabai.zig: certificate not found, run --install-cert first\n") catch {};
        return 1;
    }

    stdout.writeAll("yabai.zig: signing binary...\n") catch {};
    if (runCmd(&.{ "/usr/bin/codesign", "-fs", CERT_NAME, exe_path }, false) != 0) {
        stderr.writeAll("yabai.zig: failed to sign binary\n") catch {};
        return 1;
    }

    stdout.writeAll("yabai.zig: binary signed successfully\n") catch {};
    return 0;
}

// =============================================================================
// SA pattern analysis
// =============================================================================

fn checkSA(allocator: std.mem.Allocator, binary_path: []const u8) u8 {
    const stdout = getStdout();
    const stderr = getStderr();

    stdout.writeAll("SA Pattern Analysis\n") catch {};
    stdout.writeAll("═══════════════════════════════════════════════════════════════\n\n") catch {};

    // Print binary path
    var path_buf: [512]u8 = undefined;
    const path_msg = std.fmt.bufPrint(&path_buf, "Binary: {s}\n", .{binary_path}) catch return 1;
    stdout.writeAll(path_msg) catch {};

    // Get OS version
    const os_version = sa_extractor.getCurrentOSVersion() catch {
        stderr.writeAll("error: cannot determine macOS version\n") catch {};
        return 1;
    };
    var ver_buf: [64]u8 = undefined;
    const ver_msg = std.fmt.bufPrint(&ver_buf, "macOS:  {}.{}.{}\n\n", .{ os_version.major, os_version.minor, os_version.patch }) catch return 1;
    stdout.writeAll(ver_msg) catch {};

    // Read binary
    const binary_data = std.fs.cwd().readFileAlloc(allocator, binary_path, 32 * 1024 * 1024) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "error: cannot read binary: {}\n", .{err}) catch return 1;
        stderr.writeAll(err_msg) catch {};
        return 1;
    };
    defer allocator.free(binary_data);

    // Extract arm64 slice
    const arm64_data = sa_extractor.extractArm64Slice(binary_data) orelse {
        stderr.writeAll("error: no arm64 slice found in binary\n") catch {};
        return 1;
    };

    var size_buf: [64]u8 = undefined;
    const size_msg = std.fmt.bufPrint(&size_buf, "Size:   {} bytes (arm64 slice: {} bytes)\n\n", .{ binary_data.len, arm64_data.len }) catch return 1;
    stdout.writeAll(size_msg) catch {};

    // Run discovery
    const result = sa_extractor.discoverFunctions(allocator, arm64_data) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "error: discovery failed: {}\n", .{err}) catch return 1;
        stderr.writeAll(err_msg) catch {};
        return 1;
    };

    // Print diagnostic report
    var report_buf: [8192]u8 = undefined;
    const report = result.toDiagnosticReport(&report_buf);
    stdout.writeAll(report) catch {};

    // Return success only if all functions found
    return if (result.foundCount() == 7) 0 else 1;
}

// =============================================================================
// Scripting Addition (SA) management
// =============================================================================

const SA_OSAX_PATH = "/Library/ScriptingAdditions/yabai.zig.osax";
const SA_PAYLOAD_PATH = SA_OSAX_PATH ++ "/Contents/MacOS/payload";

fn loadSA() u8 {
    const stdout = getStdout();
    const stderr = getStderr();

    // Check if running as root
    if (std.c.getuid() != 0) {
        stderr.writeAll("yabai.zig: scripting-addition must be loaded as root!\n") catch {};
        stderr.writeAll("Run: sudo yabai.zig --load-sa\n") catch {};
        return 1;
    }

    // Check SIP status
    if (!checkSIPStatus()) {
        stderr.writeAll("yabai.zig: System Integrity Protection must have Debugging Restrictions disabled!\n") catch {};
        return 1;
    }

    // Install SA if needed
    if (!installSAFiles()) {
        stderr.writeAll("yabai.zig: failed to install scripting-addition files\n") catch {};
        return 1;
    }

    // Check if already injected
    if (sa_injector.isAlreadyInjected()) {
        stdout.writeAll("yabai.zig: scripting-addition already loaded\n") catch {};
        return 0;
    }

    // Get Dock PID
    const dock_pid = workspace.getDockPid();
    if (dock_pid == 0) {
        stderr.writeAll("yabai.zig: could not find Dock.app\n") catch {};
        return 1;
    }

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "yabai.zig: injecting SA into Dock (pid={})\n", .{dock_pid}) catch "yabai.zig: injecting SA into Dock\n";
    stdout.writeAll(msg) catch {};

    // Find our loader binary (next to this executable)
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        stderr.writeAll("yabai.zig: could not determine executable path\n") catch {};
        return 1;
    };

    // Get directory of executable
    const exe_dir = std.fs.path.dirname(exe_path) orelse {
        stderr.writeAll("yabai.zig: could not determine executable directory\n") catch {};
        return 1;
    };

    // Build loader path
    var loader_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const loader_path = std.fmt.bufPrint(&loader_path_buf, "{s}/yabai.zig-sa-loader", .{exe_dir}) catch {
        stderr.writeAll("yabai.zig: path buffer overflow\n") catch {};
        return 1;
    };

    // Check loader exists
    std.fs.accessAbsolute(loader_path, .{}) catch {
        stderr.writeAll("yabai.zig: loader binary not found at ") catch {};
        stderr.writeAll(loader_path) catch {};
        stderr.writeAll("\n") catch {};
        return 1;
    };

    // Build pid string
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{}", .{dock_pid}) catch {
        stderr.writeAll("yabai.zig: pid format error\n") catch {};
        return 1;
    };

    // Run loader: yabai.zig-sa-loader <pid> <payload_path>
    var child = std.process.Child.init(&.{ loader_path, pid_str, SA_PAYLOAD_PATH }, std.heap.page_allocator);
    child.spawn() catch {
        stderr.writeAll("yabai.zig: failed to spawn loader\n") catch {};
        return 1;
    };

    const term = child.wait() catch {
        stderr.writeAll("yabai.zig: failed to wait for loader\n") catch {};
        return 1;
    };

    if (term.Exited == 0) {
        stdout.writeAll("yabai.zig: scripting-addition loaded successfully\n") catch {};
        return 0;
    } else {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "yabai.zig: loader exited with code {}\n", .{term.Exited}) catch "yabai.zig: loader failed\n";
        stderr.writeAll(err_msg) catch {};
        return 1;
    }
}

fn unloadSA() u8 {
    const stdout = getStdout();
    const stderr = getStderr();

    // Check if running as root
    if (std.c.getuid() != 0) {
        stderr.writeAll("yabai.zig: scripting-addition must be unloaded as root!\n") catch {};
        stderr.writeAll("Run: sudo yabai.zig --unload-sa\n") catch {};
        return 1;
    }

    // Remove SA directory
    std.fs.deleteTreeAbsolute(SA_OSAX_PATH) catch |err| {
        if (err != error.FileNotFound) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "yabai.zig: failed to remove {s}: {}\n", .{ SA_OSAX_PATH, err }) catch "yabai.zig: failed to remove SA\n";
            stderr.writeAll(err_msg) catch {};
            return 1;
        }
    };

    stdout.writeAll("yabai.zig: scripting-addition unloaded (Dock restart required)\n") catch {};
    stdout.writeAll("Run: killall Dock\n") catch {};
    return 0;
}

fn killDock() u8 {
    const stdout = getStdout();
    stdout.writeAll("yabai.zig: killing Dock...\n") catch {};
    return runCmd(&.{ "/usr/bin/killall", "Dock" }, false);
}

fn reloadSA() u8 {
    const stdout = getStdout();
    const stderr = getStderr();

    // Check if running as root
    if (std.c.getuid() != 0) {
        stderr.writeAll("yabai.zig: --reload-sa must be run as root!\n") catch {};
        stderr.writeAll("Run: sudo yabai.zig --reload-sa\n") catch {};
        return 1;
    }

    // Install SA files first
    if (!installSAFiles()) {
        stderr.writeAll("yabai.zig: failed to install scripting-addition files\n") catch {};
        return 1;
    }

    // Kill Dock
    stdout.writeAll("yabai.zig: killing Dock...\n") catch {};
    _ = runCmd(&.{ "/usr/bin/killall", "Dock" }, true);

    // Wait for Dock to restart
    stdout.writeAll("yabai.zig: waiting for Dock to restart...\n") catch {};
    var dock_pid: i32 = 0;
    for (0..50) |_| { // 5 seconds max
        std.Thread.sleep(100 * std.time.ns_per_ms);
        dock_pid = workspace.getDockPid();
        if (dock_pid != 0) break;
    }

    if (dock_pid == 0) {
        stderr.writeAll("yabai.zig: Dock did not restart\n") catch {};
        return 1;
    }

    // Wait for Dock to fully initialize before injection
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Now inject
    return loadSA();
}

fn installSudoers() u8 {
    const stdout = getStdout();
    const stderr = getStderr();

    const user = std.posix.getenv("USER") orelse {
        stderr.writeAll("yabai.zig: USER not set\n") catch {};
        return 1;
    };

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        stderr.writeAll("yabai.zig: cannot determine executable path\n") catch {};
        return 1;
    };

    // Create sudoers entries for --load-sa and --reload-sa
    // Restricted to specific arguments only (no hash - allows rebuilds)
    var entry_buf: [2048]u8 = undefined;
    const entry = std.fmt.bufPrint(&entry_buf,
        \\{s} ALL=(root) NOPASSWD: {s} --load-sa
        \\{s} ALL=(root) NOPASSWD: {s} --reload-sa
        \\
    , .{ user, exe_path, user, exe_path }) catch {
        stderr.writeAll("yabai.zig: path too long\n") catch {};
        return 1;
    };

    // Write to temp file
    const tmp_path = "/tmp/yabai-zig-sudoers";
    const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch {
        stderr.writeAll("yabai.zig: failed to create temp file\n") catch {};
        return 1;
    };
    tmp_file.writeAll(entry) catch {
        tmp_file.close();
        stderr.writeAll("yabai.zig: failed to write sudoers entry\n") catch {};
        return 1;
    };
    tmp_file.close();

    // Use visudo to validate and install
    stdout.writeAll("yabai.zig: validating sudoers entry with visudo...\n") catch {};

    var script_buf: [2048]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\do shell script "visudo -c -f {s} && cp {s} /etc/sudoers.d/yabai-zig && chmod 440 /etc/sudoers.d/yabai-zig" with administrator privileges
    , .{ tmp_path, tmp_path }) catch {
        stderr.writeAll("yabai.zig: script too long\n") catch {};
        return 1;
    };

    var child = std.process.Child.init(&.{ "/usr/bin/osascript", "-e", script }, std.heap.page_allocator);
    child.spawn() catch {
        stderr.writeAll("yabai.zig: failed to run visudo\n") catch {};
        return 1;
    };

    const term = child.wait() catch {
        stderr.writeAll("yabai.zig: visudo wait failed\n") catch {};
        return 1;
    };

    // Clean up temp file
    std.fs.deleteFileAbsolute(tmp_path) catch {};

    if (term.Exited == 0) {
        stdout.writeAll("yabai.zig: sudoers entry installed - --load-sa will no longer require password\n") catch {};
        return 0;
    } else {
        stderr.writeAll("yabai.zig: failed to install sudoers entry (cancelled or invalid)\n") catch {};
        return 1;
    }
}

fn getSha256Hash(path: []const u8, out: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = file.read(&buf) catch return null;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (out.len < hex.len) return null;
    @memcpy(out[0..hex.len], &hex);
    return out[0..hex.len];
}

fn checkSIPStatus() bool {
    // Check csrutil status - we need Debugging Restrictions disabled
    var child = std.process.Child.init(&.{ "/usr/bin/csrutil", "status" }, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;

    var output_buf: [4096]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |stdout| {
        while (total < output_buf.len) {
            const n = stdout.read(output_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }

    // Don't wait - may panic due to SIGCHLD handling
    // Just check output for what we need
    const output = output_buf[0..total];

    // Look for "Debugging Restrictions: disabled"
    if (std.mem.indexOf(u8, output, "Debugging Restrictions: disabled") != null) {
        return true;
    }

    // Also accept "System Integrity Protection status: disabled"
    if (std.mem.indexOf(u8, output, "status: disabled") != null) {
        return true;
    }

    return false;
}

// Embedded SA payload dylib (compiled from payload.m at build time)
const sa_payload_bytes = @embedFile("sa_payload");

fn installSAFiles() bool {
    // Create directory structure
    std.fs.makeDirAbsolute(SA_OSAX_PATH) catch |err| {
        if (err != error.PathAlreadyExists) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "yabai.zig: failed to create {s}: {}\n", .{ SA_OSAX_PATH, err }) catch "yabai.zig: failed to create SA dir\n";
            getStderr().writeAll(err_msg) catch {};
            return false;
        }
    };

    const contents_macos = SA_OSAX_PATH ++ "/Contents/MacOS";
    std.fs.makeDirAbsolute(SA_OSAX_PATH ++ "/Contents") catch |err| {
        if (err != error.PathAlreadyExists) return false;
    };
    std.fs.makeDirAbsolute(contents_macos) catch |err| {
        if (err != error.PathAlreadyExists) return false;
    };

    // Write embedded payload to disk
    const file = std.fs.createFileAbsolute(SA_PAYLOAD_PATH, .{}) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "yabai.zig: failed to create payload: {}\n", .{err}) catch "yabai.zig: failed to create payload\n";
        getStderr().writeAll(err_msg) catch {};
        return false;
    };
    defer file.close();

    file.writeAll(sa_payload_bytes) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "yabai.zig: failed to write payload: {}\n", .{err}) catch "yabai.zig: failed to write payload\n";
        getStderr().writeAll(err_msg) catch {};
        return false;
    };

    // Make executable
    file.chmod(0o755) catch return false;

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "yabai.zig: installed SA to {s}\n", .{SA_OSAX_PATH}) catch "yabai.zig: installed SA\n";
    getStdout().writeAll(msg) catch {};
    return true;
}

/// Check if SA is available (socket exists)
fn checkSAAvailable() bool {
    const user = std.posix.getenv("USER") orelse return false;
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/yabai.zig-sa_{s}.socket", .{user}) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// Initialize SA - load if needed with GUI sudo prompt
fn initSA() void {
    if (checkSAAvailable()) {
        log.info("SA: loaded", .{});
        return;
    }

    // Get our executable path
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        log.warn("SA: cannot determine executable path", .{});
        return;
    };

    // Payload is embedded, so it's always available
    log.info("SA: not loaded, requesting authorization...", .{});

    // Use osascript to run with admin privileges (shows GUI prompt)
    var script_buf: [1024]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf, "do shell script \"{s} --load-sa\" with administrator privileges", .{exe_path}) catch {
        log.warn("SA: script too long", .{});
        return;
    };

    var child = std.process.Child.init(&.{ "/usr/bin/osascript", "-e", script }, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.warn("SA: failed to spawn osascript: {}", .{err});
        return;
    };

    // Read stderr for error messages
    var err_buf: [512]u8 = undefined;
    var err_len: usize = 0;
    if (child.stderr) |stderr| {
        err_len = stderr.read(&err_buf) catch 0;
    }

    // Wait for completion (user may cancel)
    const term = child.wait() catch {
        log.warn("SA: osascript wait failed", .{});
        return;
    };

    if (term.Exited == 0) {
        log.info("SA: loaded successfully", .{});
    } else {
        if (err_len > 0) {
            // User cancelled or auth failed
            const err_msg = std.mem.trim(u8, err_buf[0..err_len], " \t\n\r");
            if (std.mem.indexOf(u8, err_msg, "User canceled") != null) {
                log.info("SA: authorization cancelled by user", .{});
            } else {
                log.warn("SA: load failed: {s}", .{err_msg});
            }
        } else {
            log.warn("SA: load failed (exit {})", .{term.Exited});
        }
    }
}

fn startDaemon(skip_checks: bool) u8 {
    // Open log file for debugging
    log_file = std.fs.createFileAbsolute("/tmp/yabai.zig.log", .{ .truncate = true }) catch null;
    defer if (log_file) |f| f.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var daemon = Daemon.initWithOptions(allocator, .{
        .skip_checks = skip_checks,
        .record_path = g.record_path,
    }) catch |err| {
        switch (err) {
            error.RunningAsRoot => log.err("yabai.zig cannot run as root", .{}),
            error.NoAccessibility => log.err("accessibility permissions required", .{}),
            error.SeparateSpacesDisabled => log.err("enable 'displays have separate spaces' in System Settings", .{}),
            error.LockFileAcquire => log.err("another instance is already running", .{}),
            else => log.err("initialization failed: {}", .{err}),
        }
        return 1;
    };
    defer daemon.deinit();

    // Start IPC server now that daemon is at its final address
    daemon.startServer() catch |err| {
        log.err("failed to start IPC server: {}", .{err});
        return 1;
    };

    // Discover SA capabilities (for space management, window focus, etc.)
    daemon.discoverSACapabilities();

    // Start workspace observer for NSWorkspace notifications
    daemon.startWorkspaceObserver();

    // Start display observer for connect/disconnect events
    daemon.startDisplayObserver();

    // Load config file BEFORE scanning apps so padding/external_bar is applied
    const config_path = if (g.config_file[0] != 0) blk: {
        const len = std.mem.indexOf(u8, &g.config_file, &[_]u8{0}) orelse g.config_file.len;
        daemon.setConfigPath(g.config_file[0..len]);
        break :blk g.config_file[0..len];
    } else blk: {
        // Default config path: ~/.config/yabai.zig/config
        const home = std.posix.getenv("HOME") orelse break :blk @as(?[]const u8, null);
        var default_buf: [512]u8 = undefined;
        const default_path = std.fmt.bufPrint(&default_buf, "{s}/.config/yabai.zig/config", .{home}) catch break :blk null;
        break :blk @as(?[]const u8, default_path);
    };

    if (config_path) |path| {
        daemon.config.parseFile(path) catch |err| {
            log.warn("failed to load config {s}: {}", .{ path, err });
        };
        daemon.syncConfigToState();
        log.info("loaded config from {s}", .{path});
    }

    // Start tracking running applications for auto-tiling (after config loaded)
    daemon.startApplicationTracking();

    if (g.record_path != null) {
        log.info("yabai.zig {s} started (recording to {s})", .{ Version.string(), g.record_path.? });
    } else {
        log.info("yabai.zig {s} started", .{Version.string()});
    }

    // Run the main event loop (blocks until stopped or timeout)
    if (g.timeout_ms) |timeout| {
        log.info("debug: will exit after {}ms", .{timeout});
        daemon.runWithTimeout(timeout);
    } else {
        daemon.run();
    }

    return 0;
}

test "version string" {
    const v = Version.string();
    try std.testing.expect(v.len > 0);
}

test {
    // Core types
    _ = geometry;
    _ = Window;
    _ = Application;
    _ = Space;
    _ = Display;
    _ = View;
    _ = Layout;
    _ = Rule;
    _ = Animation;

    // Config
    _ = Config;
    _ = Hotload;

    // Events
    _ = Event;
    _ = EventLoop;
    _ = Mouse;
    _ = Signal;
    _ = Store;
    _ = Emulator;

    // State
    _ = Windows;
    _ = Spaces;
    _ = Displays;
    _ = Apps;

    // Platform layer
    _ = ax;
    _ = runloop;
    _ = workspace;

    // IPC
    _ = Server;
    _ = Message;
    _ = CommandHandler;
    _ = Response;

    // SA
    _ = sa_extractor;

    // Daemon (includes daemon/layout tests)
    _ = Daemon;
}
