//! SA Injector - Injects payload dylib into Dock.app
//!
//! Uses Mach APIs to inject a dylib into the Dock process. This requires either:
//! - SIP disabled, or
//! - Proper entitlements (task_for_pid-allow)
//!
//! Safety features:
//! - Comptime shellcode validation
//! - RAII-style resource cleanup via errdefer
//! - Timeout protection
//! - Architecture-specific code paths verified at comptime

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.sa_injector);

// ============================================================================
// Public API
// ============================================================================

pub const InjectorError = error{
    DockNotFound,
    DockNotReady,
    TaskForPidFailed,
    AllocationFailed,
    WriteFailed,
    ProtectFailed,
    ThreadCreateFailed,
    ThreadStateFailed,
    InjectionTimeout,
    SymbolNotFound,
    PayloadPathTooLong,
    AlreadyInjected,
};

/// Result of injection attempt with detailed status
pub const InjectionResult = union(enum) {
    success: void,
    already_injected: void,
    failed: InjectorError,

    pub fn isOk(self: InjectionResult) bool {
        return self == .success or self == .already_injected;
    }
};

/// Configuration for injection
pub const Config = struct {
    /// Maximum time to wait for injection completion (ms)
    timeout_ms: u32 = 300,
    /// Number of retries for thread state polling
    poll_retries: u32 = 15,
    /// Delay between poll attempts (ms)
    poll_delay_ms: u32 = 20,
    /// Whether to skip if already injected
    skip_if_injected: bool = true,
};

/// Inject payload dylib into Dock.app
/// Returns success, already_injected, or error details
pub fn inject(payload_path: []const u8, config: Config) InjectionResult {
    return injectImpl(payload_path, config) catch |err| .{ .failed = err };
}

/// Check if SA is already injected by testing if socket exists
pub fn isAlreadyInjected() bool {
    const user = std.posix.getenv("USER") orelse return false;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/yabai.zig-sa_{s}.socket", .{user}) catch return false;

    return std.fs.accessAbsolute(path, .{}) != error.FileNotFound;
}

// ============================================================================
// Implementation
// ============================================================================

fn injectImpl(payload_path: []const u8, config: Config) InjectorError!InjectionResult {
    // Check if already injected
    if (config.skip_if_injected and isAlreadyInjected()) {
        log.info("SA already injected (socket exists)", .{});
        return .already_injected;
    }

    // Validate payload path length at runtime (comptime check for max)
    if (payload_path.len >= Shellcode.max_path_len) {
        log.err("payload path too long: {} >= {}", .{ payload_path.len, Shellcode.max_path_len });
        return error.PayloadPathTooLong;
    }

    // Verify payload file exists
    std.fs.accessAbsolute(payload_path, .{}) catch |err| {
        log.err("payload not accessible at '{s}': {}", .{ payload_path, err });
        return error.PayloadPathTooLong; // Reusing error for "bad path"
    };

    // Get Dock PID
    const dock_pid = getDockPid() orelse {
        log.err("could not locate Dock.app pid", .{});
        return error.DockNotFound;
    };
    log.info("found Dock.app (pid={})", .{dock_pid});

    // Acquire task port (this is the privileged operation)
    var task_port = TaskPort.acquire(dock_pid) catch |err| {
        log.err("task_for_pid failed: {} (requires SIP disabled or entitlements)", .{err});
        return error.TaskForPidFailed;
    };
    defer task_port.release();
    log.debug("acquired task port", .{});

    // Allocate and setup remote memory
    var remote_mem = RemoteMemory.allocate(task_port.port, payload_path) catch |err| {
        log.err("failed to setup remote memory: {}", .{err});
        return err;
    };
    defer remote_mem.cleanup(task_port.port);
    log.debug("allocated remote memory (code=0x{x}, stack=0x{x})", .{ remote_mem.code_addr, remote_mem.stack_addr });

    // Create and run remote thread
    var remote_thread = RemoteThread.create(task_port.port, remote_mem) catch |err| {
        log.err("failed to create remote thread: {}", .{err});
        return err;
    };
    defer remote_thread.terminate();

    // Wait for completion
    if (remote_thread.waitForCompletion(config.poll_retries, config.poll_delay_ms)) {
        log.info("SA payload injected successfully", .{});
        return .success;
    }

    log.err("injection timed out waiting for thread completion", .{});
    return error.InjectionTimeout;
}

// ============================================================================
// RAII Wrappers for safe resource management
// ============================================================================

/// RAII wrapper for Mach task port
const TaskPort = struct {
    port: mach_port_t,

    fn acquire(pid: std.posix.pid_t) !TaskPort {
        var port: mach_port_t = 0;
        const kr = mach.task_for_pid(mach.mach_task_self(), pid, &port);
        if (kr != mach.KERN_SUCCESS) {
            log.err("task_for_pid returned {} for pid {}", .{ kr, pid });
            return error.TaskForPidFailed;
        }
        return .{ .port = port };
    }

    fn release(self: *TaskPort) void {
        if (self.port != 0) {
            _ = mach.mach_port_deallocate(mach.mach_task_self(), self.port);
            self.port = 0;
        }
    }
};

/// RAII wrapper for remote memory allocations
const RemoteMemory = struct {
    code_addr: mach_vm_address_t,
    code_size: usize,
    stack_addr: mach_vm_address_t,
    stack_size: usize,

    const default_stack_size: usize = 16 * 1024;

    fn allocate(task: mach_port_t, payload_path: []const u8) !RemoteMemory {
        var self: RemoteMemory = .{
            .code_addr = 0,
            .code_size = 0,
            .stack_addr = 0,
            .stack_size = default_stack_size,
        };

        // Allocate stack
        var kr = mach.mach_vm_allocate(task, &self.stack_addr, self.stack_size, mach.VM_FLAGS_ANYWHERE);
        if (kr != mach.KERN_SUCCESS) return error.AllocationFailed;
        errdefer _ = mach.mach_vm_deallocate(task, self.stack_addr, self.stack_size);

        // Write dummy return address
        const dummy_ret: u64 = 0xCAFEBABE;
        kr = mach.mach_vm_write(task, self.stack_addr, @intFromPtr(&dummy_ret), @sizeOf(u64));
        if (kr != mach.KERN_SUCCESS) return error.WriteFailed;

        // Protect stack as RW
        kr = mach.vm_protect(task, self.stack_addr, self.stack_size, 1, mach.VM_PROT_READ | mach.VM_PROT_WRITE);
        if (kr != mach.KERN_SUCCESS) return error.ProtectFailed;

        // Build shellcode with embedded addresses and path
        const shellcode = Shellcode.build(payload_path) orelse return error.SymbolNotFound;
        self.code_size = shellcode.len;

        // Allocate code segment
        kr = mach.mach_vm_allocate(task, &self.code_addr, self.code_size, mach.VM_FLAGS_ANYWHERE);
        if (kr != mach.KERN_SUCCESS) return error.AllocationFailed;
        errdefer _ = mach.mach_vm_deallocate(task, self.code_addr, self.code_size);

        // Write shellcode
        kr = mach.mach_vm_write(task, self.code_addr, @intFromPtr(&shellcode), @intCast(self.code_size));
        if (kr != mach.KERN_SUCCESS) return error.WriteFailed;

        // Protect code as RX
        kr = mach.vm_protect(task, self.code_addr, self.code_size, 0, mach.VM_PROT_EXECUTE | mach.VM_PROT_READ);
        if (kr != mach.KERN_SUCCESS) return error.ProtectFailed;

        return self;
    }

    fn cleanup(self: *RemoteMemory, task: mach_port_t) void {
        if (self.code_addr != 0) {
            _ = mach.mach_vm_deallocate(task, self.code_addr, self.code_size);
            self.code_addr = 0;
        }
        if (self.stack_addr != 0) {
            _ = mach.mach_vm_deallocate(task, self.stack_addr, self.stack_size);
            self.stack_addr = 0;
        }
    }

    fn stackPointer(self: RemoteMemory) u64 {
        return self.stack_addr + (self.stack_size / 2);
    }
};

/// RAII wrapper for remote thread
const RemoteThread = struct {
    thread: thread_act_t,

    fn create(task: mach_port_t, mem: RemoteMemory) !RemoteThread {
        var thread: thread_act_t = 0;

        if (comptime builtin.cpu.arch == .aarch64) {
            try createArm64(task, mem.code_addr, mem.stackPointer(), &thread);
        } else if (comptime builtin.cpu.arch == .x86_64) {
            try createX86_64(task, mem.code_addr, mem.stackPointer(), &thread);
        } else {
            @compileError("Unsupported architecture for SA injection");
        }

        return .{ .thread = thread };
    }

    fn terminate(self: *RemoteThread) void {
        if (self.thread != 0) {
            _ = mach.thread_terminate(self.thread);
            self.thread = 0;
        }
    }

    fn waitForCompletion(self: RemoteThread, max_retries: u32, delay_ms: u32) bool {
        // Initial delay for thread startup
        std.Thread.sleep(10 * std.time.ns_per_ms);

        for (0..max_retries) |_| {
            if (self.checkComplete()) return true;
            std.Thread.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
        }
        return false;
    }

    fn checkComplete(self: RemoteThread) bool {
        // Magic value "yabe" (0x79616265) signals completion
        const magic: u64 = 0x79616265;

        if (comptime builtin.cpu.arch == .aarch64) {
            var state: arm_thread_state64_t = undefined;
            var count: mach_msg_type_number_t = arm_thread_state64_count;
            if (mach.thread_get_state(self.thread, ARM_THREAD_STATE64, @ptrCast(&state), &count) == mach.KERN_SUCCESS) {
                return state.__x[0] == magic;
            }
        } else {
            var state: x86_thread_state64_t = undefined;
            var count: mach_msg_type_number_t = x86_thread_state64_count;
            if (mach.thread_get_state(self.thread, x86_THREAD_STATE64, @ptrCast(&state), &count) == mach.KERN_SUCCESS) {
                return state.__rax == magic;
            }
        }
        return false;
    }

    fn createArm64(task: mach_port_t, code: u64, stack: u64, thread: *thread_act_t) !void {
        // Try direct thread_create_running without convert (simpler approach)
        var thread_state: arm_thread_state64_t = std.mem.zeroes(arm_thread_state64_t);
        thread_state.__opaque_pc = code;
        thread_state.__opaque_sp = stack;
        thread_state.__opaque_flags = 0x1; // NO_PTRAUTH - kernel should sign for us

        log.debug("trying direct create_running: pc=0x{x} sp=0x{x}", .{ code, stack });

        var kr = mach.thread_create_running(task, ARM_THREAD_STATE64, @ptrCast(&thread_state), arm_thread_state64_count, thread);
        if (kr == mach.KERN_SUCCESS) {
            log.debug("direct create_running succeeded", .{});
            return;
        }
        log.debug("direct create_running failed: {}, trying convert path", .{kr});

        // Fall back to convert path
        const convert_fn = getThreadConvertFn() orelse {
            log.err("failed to load thread_convert_thread_state", .{});
            return error.SymbolNotFound;
        };

        var machine_state: arm_thread_state64_t = std.mem.zeroes(arm_thread_state64_t);

        // Create suspended thread first
        kr = mach.thread_create(task, thread);
        if (kr != mach.KERN_SUCCESS) {
            log.err("thread_create failed: {}", .{kr});
            return error.ThreadCreateFailed;
        }
        errdefer _ = mach.thread_terminate(thread.*);

        // Convert thread state for arm64e
        var out_count: mach_msg_type_number_t = arm_thread_state64_count;
        kr = convert_fn(thread.*, 2, ARM_THREAD_STATE64, @ptrCast(&thread_state), arm_thread_state64_count, @ptrCast(&machine_state), &out_count);
        if (kr != mach.KERN_SUCCESS) {
            log.err("thread_convert_thread_state failed: {}", .{kr});
            return error.ThreadStateFailed;
        }
        log.debug("convert: in_pc=0x{x} out_pc=0x{x} out_sp=0x{x} out_count={}", .{
            thread_state.__opaque_pc,
            machine_state.__opaque_pc,
            machine_state.__opaque_sp,
            out_count,
        });

        // macOS 14.4+ requires terminate + create_running pattern
        _ = mach.thread_terminate(thread.*);
        kr = mach.thread_create_running(task, ARM_THREAD_STATE64, @ptrCast(&machine_state), out_count, thread);
        if (kr != mach.KERN_SUCCESS) {
            log.err("thread_create_running failed: {} (pc=0x{x})", .{ kr, machine_state.__opaque_pc });
            return error.ThreadCreateFailed;
        }
    }

    fn createX86_64(task: mach_port_t, code: u64, stack: u64, thread: *thread_act_t) !void {
        var state: x86_thread_state64_t = std.mem.zeroes(x86_thread_state64_t);
        state.__rip = code;
        state.__rsp = stack;

        const kr = mach.thread_create_running(task, x86_THREAD_STATE64, @ptrCast(&state), x86_thread_state64_count, thread);
        if (kr != mach.KERN_SUCCESS) return error.ThreadCreateFailed;
    }

    fn getThreadConvertFn() ?ThreadConvertFn {
        const handle = mach.dlopen("/usr/lib/system/libsystem_kernel.dylib", mach.RTLD_LAZY) orelse return null;
        defer _ = mach.dlclose(handle);
        const sym = mach.dlsym(handle, "thread_convert_thread_state") orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    const ThreadConvertFn = *const fn (thread_act_t, c_int, thread_state_flavor_t, thread_state_t, mach_msg_type_number_t, thread_state_t, *mach_msg_type_number_t) callconv(.c) kern_return_t;
};

// ============================================================================
// Shellcode - Architecture-specific injection code
// ============================================================================

const Shellcode = struct {
    /// Maximum payload path length supported
    pub const max_path_len: usize = 256;

    /// Total shellcode size including path buffer
    const total_size = if (builtin.cpu.arch == .aarch64) arm64_base.len + max_path_len else x86_64_base.len + max_path_len;

    const Buffer = [total_size]u8;

    /// Build shellcode with addresses and payload path embedded
    fn build(payload_path: []const u8) ?Buffer {
        // Look up required function addresses
        const pcfmt_raw = mach.dlsym(mach.RTLD_DEFAULT, "pthread_create_from_mach_thread") orelse return null;
        const dlopen_raw = mach.dlsym(mach.RTLD_DEFAULT, "dlopen") orelse return null;

        // Strip PAC on arm64
        const pcfmt_addr: u64 = @intFromPtr(pac.strip(pcfmt_raw));
        const dlopen_addr: u64 = @intFromPtr(pac.strip(dlopen_raw));

        var buf: Buffer = undefined;

        if (comptime builtin.cpu.arch == .aarch64) {
            // Copy base shellcode
            @memcpy(buf[0..arm64_base.len], &arm64_base);

            // Patch addresses (little-endian)
            @memcpy(buf[arm64_pcfmt_offset..][0..8], std.mem.asBytes(&pcfmt_addr));
            @memcpy(buf[arm64_dlopen_offset..][0..8], std.mem.asBytes(&dlopen_addr));

            // Copy payload path
            @memset(buf[arm64_path_offset..], 0);
            @memcpy(buf[arm64_path_offset..][0..payload_path.len], payload_path);
        } else {
            // Copy base shellcode
            @memcpy(buf[0..x86_64_base.len], &x86_64_base);

            // Patch addresses
            @memcpy(buf[x86_64_pcfmt_offset..][0..8], std.mem.asBytes(&pcfmt_addr));
            @memcpy(buf[x86_64_dlopen_offset..][0..8], std.mem.asBytes(&dlopen_addr));

            // Copy payload path
            @memset(buf[x86_64_path_offset..], 0);
            @memcpy(buf[x86_64_path_offset..][0..payload_path.len], payload_path);
        }

        return buf;
    }

    // ARM64 shellcode offsets
    const arm64_pcfmt_offset = 88;
    const arm64_dlopen_offset = 160;
    const arm64_path_offset = 168;

    // x86_64 shellcode offsets
    const x86_64_pcfmt_offset = 28;
    const x86_64_dlopen_offset = 71;
    const x86_64_path_offset = 90;

    // ARM64 shellcode: calls pthread_create_from_mach_thread -> dlopen
    const arm64_base = [_]u8{
        // Entry: setup and call pthread_create_from_mach_thread
        0xFF, 0xC3, 0x00, 0xD1, // sub  sp, sp, #0x30
        0xFD, 0x7B, 0x02, 0xA9, // stp  x29, x30, [sp, #0x20]
        0xFD, 0x83, 0x00, 0x91, // add  x29, sp, #0x20
        0xA0, 0xC3, 0x1F, 0xB8, // stur w0, [x29, #-0x4]
        0xE1, 0x0B, 0x00, 0xF9, // str  x1, [sp, #0x10]
        0xE0, 0x23, 0x00, 0x91, // add  x0, sp, #0x8
        0x08, 0x00, 0x80, 0xD2, // mov  x8, #0
        0xE8, 0x07, 0x00, 0xF9, // str  x8, [sp, #0x8]
        0xE1, 0x03, 0x08, 0xAA, // mov  x1, x8
        0xE2, 0x01, 0x00, 0x10, // adr  x2, thread_func
        0xE2, 0x23, 0xC1, 0xDA, // paciza x2
        0xE3, 0x03, 0x08, 0xAA, // mov  x3, x8
        0x49, 0x01, 0x00, 0x10, // adr  x9, pcfmt_addr
        0x29, 0x01, 0x40, 0xF9, // ldr  x9, [x9]
        0x20, 0x01, 0x3F, 0xD6, // blr  x9
        0xA0, 0x4C, 0x8C, 0xD2, // movz x0, #0x6265 ('be')
        0x20, 0x2C, 0xAF, 0xF2, // movk x0, #0x7961, lsl #16 ('ya')
        0x09, 0x00, 0x00, 0x10, // adr  x9, spin
        0x20, 0x01, 0x1F, 0xD6, // br   x9 (spin forever)
        0xFD, 0x7B, 0x42, 0xA9, // ldp  x29, x30, [sp, #0x20]
        0xFF, 0xC3, 0x00, 0x91, // add  sp, sp, #0x30
        0xC0, 0x03, 0x5F, 0xD6, // ret
        // pcfmt_addr placeholder (offset 88)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
        // thread_func: calls dlopen(path, RTLD_LAZY)
        0x7F, 0x23, 0x03, 0xD5, // pacibsp
        0xFF, 0xC3, 0x00, 0xD1, // sub  sp, sp, #0x30
        0xFD, 0x7B, 0x02, 0xA9, // stp  x29, x30, [sp, #0x20]
        0xFD, 0x83, 0x00, 0x91, // add  x29, sp, #0x20
        0xA0, 0xC3, 0x1F, 0xB8, // stur w0, [x29, #-0x4]
        0xE1, 0x0B, 0x00, 0xF9, // str  x1, [sp, #0x10]
        0x21, 0x00, 0x80, 0xD2, // mov  x1, #1 (RTLD_LAZY)
        0x60, 0x01, 0x00, 0x10, // adr  x0, path
        0x09, 0x01, 0x00, 0x10, // adr  x9, dlopen_addr
        0x29, 0x01, 0x40, 0xF9, // ldr  x9, [x9]
        0x20, 0x01, 0x3F, 0xD6, // blr  x9
        0x09, 0x00, 0x80, 0x52, // mov  w9, #0
        0xE0, 0x03, 0x09, 0xAA, // mov  x0, x9
        0xFD, 0x7B, 0x42, 0xA9, // ldp  x29, x30, [sp, #0x20]
        0xFF, 0xC3, 0x00, 0x91, // add  sp, sp, #0x30
        0xFF, 0x0F, 0x5F, 0xD6, // retab
        // dlopen_addr placeholder (offset 160)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
        // path starts at offset 168
    };

    // x86_64 shellcode
    const x86_64_base = [_]u8{
        0x55, // push rbp
        0x48, 0x89, 0xE5, // mov  rbp, rsp
        0x48, 0x83, 0xEC, 0x10, // sub  rsp, 0x10
        0x48, 0x8D, 0x7D, 0xF8, // lea  rdi, [rbp-0x8]
        0x31, 0xC0, // xor  eax, eax
        0x89, 0xC1, // mov  ecx, eax
        0x48, 0x8D, 0x15, 0x1E, 0x00, 0x00, 0x00, // lea rdx, thread_func
        0x48, 0x89, 0xCE, // mov  rsi, rcx
        0x48, 0xB8, // movabs rax, pcfmt
        // pcfmt_addr placeholder (offset 28)
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0xFF, 0xD0, // call rax
        0x48, 0x83, 0xC4, 0x10, // add  rsp, 0x10
        0x5D, // pop  rbp
        0x48, 0xC7, 0xC0, 0x65, 0x62, 0x61, 0x79, // mov rax, 'yabe'
        0xEB, 0xFE, // jmp  spin
        0xC3, // ret
        // thread_func
        0x55, // push rbp
        0x48, 0x89, 0xE5, // mov  rbp, rsp
        0xBE, 0x01, 0x00, 0x00, 0x00, // mov  esi, RTLD_LAZY
        0x48, 0x8D, 0x3D, 0x16, 0x00, 0x00, 0x00, // lea rdi, path
        0x48, 0xB8, // movabs rax, dlopen
        // dlopen_addr placeholder (offset 71)
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0xFF, 0xD0, // call rax
        0x31, 0xF6, // xor  esi, esi
        0x89, 0xF7, // mov  edi, esi
        0x48, 0x89, 0xF8, // mov  rax, rdi
        0x5D, // pop  rbp
        0xC3, // ret
        // path starts at offset 90
    };

    // Comptime validation
    comptime {
        if (builtin.cpu.arch == .aarch64) {
            if (arm64_path_offset != arm64_base.len) @compileError("ARM64 path offset mismatch");
        } else if (builtin.cpu.arch == .x86_64) {
            if (x86_64_path_offset != x86_64_base.len) @compileError("x86_64 path offset mismatch");
        }
    }
};

// ============================================================================
// PAC (Pointer Authentication) helpers
// ============================================================================

const pac = struct {
    /// Strip PAC bits from pointer (arm64 only, no-op on x86)
    inline fn strip(ptr: ?*anyopaque) ?*anyopaque {
        if (comptime builtin.cpu.arch != .aarch64) return ptr;
        if (ptr == null) return null;
        var result = ptr;
        asm volatile ("xpaci %[result]"
            : [result] "+r" (result),
        );
        return result;
    }

    /// Sign pointer with PAC (arm64 only, no-op on x86)
    inline fn sign(ptr: ?*anyopaque) ?*anyopaque {
        if (comptime builtin.cpu.arch != .aarch64) return ptr;
        if (ptr == null) return null;
        // pacia Xd, Xn - sign Xd using key A and modifier Xn (xzr = 0)
        var result = ptr;
        asm volatile ("paciza %[result]"
            : [result] "+r" (result),
        );
        return result;
    }
};

// ============================================================================
// Dock process discovery - delegate to workspace module
// ============================================================================

const workspace = @import("../platform/workspace.zig");

fn getDockPid() ?std.posix.pid_t {
    const pid = workspace.getDockPid();
    return if (pid > 0) pid else null;
}

// ============================================================================
// Mach types and external declarations
// ============================================================================

const kern_return_t = c_int;
const mach_port_t = c_uint;
const thread_act_t = c_uint;
const mach_vm_address_t = u64;
const vm_size_t = usize;
const thread_state_flavor_t = c_int;
const thread_state_t = *anyopaque;
const mach_msg_type_number_t = c_uint;

const ARM_THREAD_STATE64: thread_state_flavor_t = 6;
const x86_THREAD_STATE64: thread_state_flavor_t = 4;

const arm_thread_state64_t = extern struct {
    __x: [29]u64 = [_]u64{0} ** 29,
    __opaque_fp: u64 = 0,
    __opaque_lr: u64 = 0,
    __opaque_sp: u64 = 0,
    __opaque_pc: u64 = 0,
    __cpsr: u32 = 0,
    __opaque_flags: u32 = 0,
};

const x86_thread_state64_t = extern struct {
    __rax: u64 = 0,
    __rbx: u64 = 0,
    __rcx: u64 = 0,
    __rdx: u64 = 0,
    __rdi: u64 = 0,
    __rsi: u64 = 0,
    __rbp: u64 = 0,
    __rsp: u64 = 0,
    __r8: u64 = 0,
    __r9: u64 = 0,
    __r10: u64 = 0,
    __r11: u64 = 0,
    __r12: u64 = 0,
    __r13: u64 = 0,
    __r14: u64 = 0,
    __r15: u64 = 0,
    __rip: u64 = 0,
    __rflags: u64 = 0,
    __cs: u64 = 0,
    __fs: u64 = 0,
    __gs: u64 = 0,
};

const arm_thread_state64_count: mach_msg_type_number_t = @sizeOf(arm_thread_state64_t) / @sizeOf(u32);
const x86_thread_state64_count: mach_msg_type_number_t = @sizeOf(x86_thread_state64_t) / @sizeOf(u32);

/// Mach kernel and dyld functions
const mach = struct {
    const KERN_SUCCESS: kern_return_t = 0;
    const VM_FLAGS_ANYWHERE: c_int = 0x1;
    const VM_PROT_READ: c_int = 0x1;
    const VM_PROT_WRITE: c_int = 0x2;
    const VM_PROT_EXECUTE: c_int = 0x4;
    const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const RTLD_LAZY: c_int = 0x1;

    extern fn mach_task_self() mach_port_t;
    extern fn task_for_pid(target: mach_port_t, pid: std.posix.pid_t, task: *mach_port_t) kern_return_t;
    extern fn mach_port_deallocate(task: mach_port_t, name: mach_port_t) kern_return_t;
    extern fn mach_vm_allocate(task: mach_port_t, addr: *mach_vm_address_t, size: vm_size_t, flags: c_int) kern_return_t;
    extern fn mach_vm_deallocate(task: mach_port_t, addr: mach_vm_address_t, size: vm_size_t) kern_return_t;
    extern fn mach_vm_write(task: mach_port_t, addr: mach_vm_address_t, data: usize, count: c_uint) kern_return_t;
    extern fn vm_protect(task: mach_port_t, addr: mach_vm_address_t, size: vm_size_t, set_max: c_int, prot: c_int) kern_return_t;
    extern fn thread_create(task: mach_port_t, thread: *thread_act_t) kern_return_t;
    extern fn thread_create_running(task: mach_port_t, flavor: thread_state_flavor_t, state: thread_state_t, count: mach_msg_type_number_t, thread: *thread_act_t) kern_return_t;
    extern fn thread_terminate(thread: thread_act_t) kern_return_t;
    extern fn thread_get_state(thread: thread_act_t, flavor: thread_state_flavor_t, state: thread_state_t, count: *mach_msg_type_number_t) kern_return_t;
    extern fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern fn dlclose(handle: ?*anyopaque) c_int;
    extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
};

// ============================================================================
// Tests
// ============================================================================

test "shellcode offsets validated at comptime" {
    // This test passes if compilation succeeds (comptime checks in Shellcode)
    const buf = Shellcode.build("/tmp/test.dylib");
    try std.testing.expect(buf != null);
}

test "getDockPid finds Dock" {
    const pid = getDockPid();
    // Dock should always be running on macOS
    try std.testing.expect(pid != null);
    try std.testing.expect(pid.? > 0);
}

test "isAlreadyInjected returns bool" {
    // Just verify it doesn't crash
    _ = isAlreadyInjected();
}
