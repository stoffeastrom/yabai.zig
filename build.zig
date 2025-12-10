const std = @import("std");

fn linkFrameworks(mod: *std.Build.Module) void {
    mod.linkFramework("Carbon", .{});
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("CoreServices", .{});
    mod.linkFramework("CoreVideo", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SA Payload - arm64e dylib for Dock injection (must use clang)
    // Build this first so we can embed it in the main binary
    const payload_cmd = b.addSystemCommand(&.{
        "xcrun", "clang",
    });
    payload_cmd.addFileArg(b.path("src/sa/payload.m")); // Track as input dependency
    payload_cmd.addArgs(&.{
        "-shared",
        "-fPIC",
        "-O2",
        "-mmacosx-version-min=14.0",
        "-arch",
        "arm64e",
        "-framework",
        "Foundation",
        "-framework",
        "CoreFoundation",
        "-framework",
        "CoreGraphics",
        "-F/System/Library/PrivateFrameworks",
        "-framework",
        "SkyLight",
        "-o",
    });
    const payload_output = payload_cmd.addOutputFileArg("libyabai.zig-sa.dylib");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    linkFrameworks(exe_mod);
    exe_mod.linkSystemLibrary("c", .{});

    // Embed the SA payload dylib into the binary
    exe_mod.addAnonymousImport("sa_payload", .{
        .root_source_file = payload_output,
    });

    const exe = b.addExecutable(.{
        .name = "yabai.zig",
        .root_module = exe_mod,
    });

    // Embed Info.plist into __TEXT,__info_plist section for stable TCC identity
    exe.addAssemblyFile(b.path("resources/embed_plist.s"));

    b.installArtifact(exe);

    // SA Loader - arm64e binary for injection (must use clang for PAC support)
    const loader_cmd = b.addSystemCommand(&.{
        "xcrun",                     "clang",
        "src/sa/loader.m",           "-O2",
        "-mmacosx-version-min=14.0", "-arch",
        "x86_64",                    "-arch",
        "arm64e",                    "-o",
    });
    const loader_output = loader_cmd.addOutputFileArg("yabai.zig-sa-loader");

    const install_loader = b.addInstallBinFile(loader_output, "yabai.zig-sa-loader");
    b.getInstallStep().dependOn(&install_loader.step);

    // Sign step - signs main binary for stable TCC identity (requires yabai.zig-cert)
    const sign_cmd = b.addSystemCommand(&.{
        "/usr/bin/codesign",
        "-f",
        "-s",
        "yabai.zig-cert",
        "-i",
        "com.stoffeastrom.yabai.zig",
    });
    sign_cmd.addArtifactArg(exe);
    sign_cmd.step.dependOn(b.getInstallStep());

    const sign_step = b.step("sign", "Sign binary with yabai.zig-cert (for accessibility)");
    sign_step.dependOn(&sign_cmd.step);

    // Ad-hoc sign step - for CI/releases (no certificate required)
    const adhoc_sign_cmd = b.addSystemCommand(&.{
        "/usr/bin/codesign",
        "-f",
        "-s",
        "-", // ad-hoc signature
        "-i",
        "com.stoffeastrom.yabai.zig",
    });
    adhoc_sign_cmd.addArtifactArg(exe);
    adhoc_sign_cmd.step.dependOn(b.getInstallStep());

    const adhoc_sign_step = b.step("sign-adhoc", "Ad-hoc sign binary (for CI/releases)");
    adhoc_sign_step.dependOn(&adhoc_sign_cmd.step);

    // Run step (without signing - use for development/testing)
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run yabai.zig");
    run_step.dependOn(&run_cmd.step);

    // Dev helper - stops yabai, runs yabai.zig, restarts yabai on exit
    const dev_mod = b.createModule(.{
        .root_source_file = b.path("scripts/dev.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dev_exe = b.addExecutable(.{
        .name = "yabai.zig-dev",
        .root_module = dev_mod,
    });
    b.installArtifact(dev_exe);

    const dev_run = b.addRunArtifact(dev_exe);
    dev_run.step.dependOn(b.getInstallStep()); // Main exe built and signed
    dev_run.step.dependOn(&dev_exe.step); // Build dev helper
    if (b.args) |args| {
        dev_run.addArgs(args);
    }

    const dev_step = b.step("dev", "Stop yabai, run yabai.zig, restart yabai on exit");
    dev_step.dependOn(&dev_run.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(test_mod);
    test_mod.linkSystemLibrary("c", .{});

    const exe_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    // Fast check-sa executable for development
    const check_sa_mod = b.createModule(.{
        .root_source_file = b.path("src/sa/check_sa.zig"),
        .target = target,
        .optimize = .Debug, // Fast builds for development
    });
    check_sa_mod.linkSystemLibrary("c", .{});

    const check_sa_exe = b.addExecutable(.{
        .name = "yabai.zig-check-sa",
        .root_module = check_sa_mod,
    });

    b.installArtifact(check_sa_exe);

    // Check SA step - fast analysis for development
    const check_sa_step = b.step("check-sa", "Fast SA pattern analysis (development)");
    const check_sa_fast_run = b.addRunArtifact(check_sa_exe);
    check_sa_step.dependOn(&check_sa_fast_run.step);

    // Full check-sa (builds entire binary first)
    const check_sa_full_step = b.step("check-sa-full", "Full SA analysis (builds complete binary)");
    const check_sa_run = b.addRunArtifact(exe);
    check_sa_run.addArgs(&.{"--check-sa"});
    check_sa_full_step.dependOn(b.getInstallStep());
    check_sa_full_step.dependOn(&check_sa_run.step);

    // SA management steps (use full binary)
    const load_sa_step = b.step("load-sa", "Install and load scripting addition (requires sudo)");
    const load_sa_run = b.addRunArtifact(exe);
    load_sa_run.addArgs(&.{"--load-sa"});
    load_sa_step.dependOn(b.getInstallStep());
    load_sa_step.dependOn(&load_sa_run.step);

    const reload_sa_step = b.step("reload-sa", "Kill Dock and re-inject SA (requires sudo)");
    const reload_sa_run = b.addRunArtifact(exe);
    reload_sa_run.addArgs(&.{"--reload-sa"});
    reload_sa_step.dependOn(b.getInstallStep());
    reload_sa_step.dependOn(&reload_sa_run.step);
}
