// SA Loader - arm64e binary for injecting payload into Dock
// Must be compiled with -arch arm64e to use PAC intrinsics

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

#ifdef __arm64__
#include <ptrauth.h>
#endif

kern_return_t (*_thread_convert_thread_state)(thread_act_t thread, int direction, thread_state_flavor_t flavor, thread_state_t in_state, mach_msg_type_number_t in_stateCnt, thread_state_t out_state, mach_msg_type_number_t *out_stateCnt);

static char shell_code[] =
#ifdef __x86_64__
"\x55"                             // push       rbp
"\x48\x89\xE5"                     // mov        rbp, rsp
"\x48\x83\xEC\x10"                 // sub        rsp, 0x10
"\x48\x8D\x7D\xF8"                 // lea        rdi, qword [rbp+var_8]
"\x31\xC0"                         // xor        eax, eax
"\x89\xC1"                         // mov        ecx, eax
"\x48\x8D\x15\x1E\x00\x00\x00"     // lea        rdx, qword ptr [rip+0x1E]
"\x48\x89\xCE"                     // mov        rsi, rcx
"\x48\xB8"                         // movabs     rax, pthread_create_from_mach_thread
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\xFF\xD0"                         // call       rax
"\x48\x83\xC4\x10"                 // add        rsp, 0x10
"\x5D"                             // pop        rbp
"\x48\xC7\xC0\x65\x62\x61\x79"     // mov        rax, 0x79616265
"\xEB\xFE"                         // jmp        0x0
"\xC3"                             // ret
"\x55"                             // push       rbp
"\x48\x89\xE5"                     // mov        rbp, rsp
"\xBE\x01\x00\x00\x00"             // mov        esi, 0x1
"\x48\x8D\x3D\x16\x00\x00\x00"     // lea        rdi, qword ptr [rip+0x16]
"\x48\xB8"                         // movabs     rax, dlopen
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\xFF\xD0"                         // call       rax
"\x31\xF6"                         // xor        esi, esi
"\x89\xF7"                         // mov        edi, esi
"\x48\x89\xF8"                     // mov        rax, rdi
"\x5D"                             // pop        rbp
"\xC3"                             // ret
#elif __arm64__
"\xFF\xC3\x00\xD1"                 // sub        sp, sp, #0x30
"\xFD\x7B\x02\xA9"                 // stp        x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                 // add        x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                 // stur       w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                 // str        x1, [sp, #0x10]
"\xE0\x23\x00\x91"                 // add        x0, sp, #0x8
"\x08\x00\x80\xD2"                 // mov        x8, #0
"\xE8\x07\x00\xF9"                 // str        x8, [sp, #0x8]
"\xE1\x03\x08\xAA"                 // mov        x1, x8
"\xE2\x01\x00\x10"                 // adr        x2, #0x3C
"\xE2\x23\xC1\xDA"                 // paciza     x2
"\xE3\x03\x08\xAA"                 // mov        x3, x8
"\x49\x01\x00\x10"                 // adr        x9, #0x28 ; pthread_create_from_mach_thread
"\x29\x01\x40\xF9"                 // ldr        x9, [x9]
"\x20\x01\x3F\xD6"                 // blr        x9
"\xA0\x4C\x8C\xD2"                 // movz       x0, #0x6265
"\x20\x2C\xAF\xF2"                 // movk       x0, #0x7961, lsl #16
"\x09\x00\x00\x10"                 // adr        x9, #0
"\x20\x01\x1F\xD6"                 // br         x9
"\xFD\x7B\x42\xA9"                 // ldp        x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                 // add        sp, sp, #0x30
"\xC0\x03\x5F\xD6"                 // ret
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\x7F\x23\x03\xD5"                 // pacibsp
"\xFF\xC3\x00\xD1"                 // sub        sp, sp, #0x30
"\xFD\x7B\x02\xA9"                 // stp        x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                 // add        x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                 // stur       w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                 // str        x1, [sp, #0x10]
"\x21\x00\x80\xD2"                 // mov        x1, #1
"\x60\x01\x00\x10"                 // adr        x0, #0x2c ; payload_path
"\x09\x01\x00\x10"                 // adr        x9, #0x20 ; dlopen
"\x29\x01\x40\xF9"                 // ldr        x9, [x9]
"\x20\x01\x3F\xD6"                 // blr        x9
"\x09\x00\x80\x52"                 // mov        w9, #0
"\xE0\x03\x09\xAA"                 // mov        x0, x9
"\xFD\x7B\x42\xA9"                 // ldp        x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                 // add        sp, sp, #0x30
"\xFF\x0F\x5F\xD6"                 // retab
"\x00\x00\x00\x00\x00\x00\x00\x00" //
#endif
"\x00\x00\x00\x00\x00\x00\x00\x00" // empty space for payload_path (256 bytes)
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00";

// Usage: yabai-sa-loader <pid> <payload_path>
int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <pid> <payload_path>\n", argv[0]);
        return 1;
    }

    pid_t pid = atoi(argv[1]);
    char *payload_path = argv[2];

    if (pid <= 0) {
        fprintf(stderr, "invalid pid: %s\n", argv[1]);
        return 1;
    }

    if (strlen(payload_path) >= 256) {
        fprintf(stderr, "payload path too long\n");
        return 1;
    }

    int result = 0;
    mach_port_t task = 0;
    thread_act_t thread = 0;
    mach_vm_address_t code = 0;
    mach_vm_address_t stack = 0;
    vm_size_t stack_size = 16 * 1024;
    uint64_t stack_contents = 0x00000000CAFEBABE;

    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid failed for pid %d\n", pid);
        return 1;
    }

    if (mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "could not allocate stack\n");
        return 1;
    }

    if (mach_vm_write(task, stack, (vm_address_t) &stack_contents, sizeof(uint64_t)) != KERN_SUCCESS) {
        fprintf(stderr, "could not write stack\n");
        return 1;
    }

    if (vm_protect(task, stack, stack_size, 1, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        fprintf(stderr, "could not protect stack\n");
        return 1;
    }

    if (mach_vm_allocate(task, &code, sizeof(shell_code), VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "could not allocate code\n");
        return 1;
    }

#ifdef __x86_64__
    uint64_t pcfmt_address = (uint64_t) dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread");
    uint64_t dlopen_address = (uint64_t) dlsym(RTLD_DEFAULT, "dlopen");

    memcpy(shell_code + 28, &pcfmt_address, sizeof(uint64_t));
    memcpy(shell_code + 71, &dlopen_address, sizeof(uint64_t));
    memcpy(shell_code + 90, payload_path, strlen(payload_path));
#elif __arm64__
    uint64_t pcfmt_address = (uint64_t) ptrauth_strip(dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"), ptrauth_key_function_pointer);
    uint64_t dlopen_address = (uint64_t) ptrauth_strip(dlsym(RTLD_DEFAULT, "dlopen"), ptrauth_key_function_pointer);

    memcpy(shell_code + 88, &pcfmt_address, sizeof(uint64_t));
    memcpy(shell_code + 160, &dlopen_address, sizeof(uint64_t));
    memcpy(shell_code + 168, payload_path, strlen(payload_path));
#endif

    if (mach_vm_write(task, code, (vm_address_t) shell_code, sizeof(shell_code)) != KERN_SUCCESS) {
        fprintf(stderr, "could not write shellcode\n");
        return 1;
    }

    if (vm_protect(task, code, sizeof(shell_code), 0, VM_PROT_EXECUTE | VM_PROT_READ) != KERN_SUCCESS) {
        fprintf(stderr, "could not protect code\n");
        return 1;
    }

#ifdef __x86_64__
    x86_thread_state64_t thread_state = {};
    thread_state_flavor_t thread_flavor = x86_THREAD_STATE64;
    mach_msg_type_number_t thread_flavor_count = x86_THREAD_STATE64_COUNT;

    thread_state.__rip = (uint64_t) code;
    thread_state.__rsp = (uint64_t) stack + (stack_size / 2);

    kern_return_t error = thread_create_running(task, thread_flavor, (thread_state_t)&thread_state, thread_flavor_count, &thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "thread_create_running failed: %d\n", error);
        return 1;
    }
#elif __arm64__
    void *handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (handle) {
        _thread_convert_thread_state = dlsym(handle, "thread_convert_thread_state");
        dlclose(handle);
    }

    if (!_thread_convert_thread_state) {
        fprintf(stderr, "could not load thread_convert_thread_state\n");
        return 1;
    }

    arm_thread_state64_t thread_state = {}, machine_thread_state = {};
    thread_state_flavor_t thread_flavor = ARM_THREAD_STATE64;
    mach_msg_type_number_t thread_flavor_count = ARM_THREAD_STATE64_COUNT, machine_thread_flavor_count = ARM_THREAD_STATE64_COUNT;

    __darwin_arm_thread_state64_set_pc_fptr(thread_state, ptrauth_sign_unauthenticated((void *) code, ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(thread_state, stack + (stack_size / 2));

    kern_return_t error = thread_create(task, &thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "thread_create failed: %d\n", error);
        return 1;
    }

    error = _thread_convert_thread_state(thread, 2, thread_flavor, (thread_state_t) &thread_state, thread_flavor_count, (thread_state_t) &machine_thread_state, &machine_thread_flavor_count);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "thread_convert_thread_state failed: %d\n", error);
        return 1;
    }

    // macOS 14.4+ path
    thread_terminate(thread);
    error = thread_create_running(task, thread_flavor, (thread_state_t)&machine_thread_state, machine_thread_flavor_count, &thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "thread_create_running failed: %d\n", error);
        return 1;
    }
#endif

    usleep(10000);

    for (int i = 0; i < 15; ++i) {
#ifdef __arm64__
        thread_flavor_count = ARM_THREAD_STATE64_COUNT;
#endif
        kern_return_t err = thread_get_state(thread, thread_flavor, (thread_state_t)&thread_state, &thread_flavor_count);

        if (err != KERN_SUCCESS) {
            result = 1;
            goto terminate;
        }

#ifdef __x86_64__
        if (thread_state.__rax == 0x79616265) {
#elif __arm64__
        if (thread_state.__x[0] == 0x79616265) {
#endif
            result = 0;
            goto terminate;
        }

        usleep(20000);
    }

    fprintf(stderr, "injection timed out\n");
    result = 1;

terminate:
    thread_terminate(thread);
    return result;
}
