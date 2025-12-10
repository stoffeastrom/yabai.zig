// SA Payload - Scripting Addition dylib injected into Dock.app
// Based on yabai's osax/payload.m - uses pattern matching to find Dock internal functions

#include <Foundation/Foundation.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach/vm_page_size.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <CoreGraphics/CoreGraphics.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <unistd.h>
#include <netdb.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>

#ifdef __arm64__
#include <ptrauth.h>
#endif

#define SOCKET_PATH_FMT "/tmp/yabai-sa_%s.socket"
#define unpack(v) memcpy(&v, message, sizeof(v)); message += sizeof(v)
#define page_align(addr) (vm_address_t)((uintptr_t)(addr) & (~(vm_page_size - 1)))
#define lerp(a, t, b) (((1.0-t)*a) + (t*b))

// Constants
#define SA_CAP_SPACE_CREATE  (1 << 0)
#define SA_CAP_SPACE_DESTROY (1 << 1)
#define SA_CAP_SPACE_MOVE    (1 << 2)

// Opcodes
#define OP_HANDSHAKE     0
#define OP_SPACE_FOCUS   1
#define OP_SPACE_CREATE  2
#define OP_SPACE_DESTROY 3
#define OP_SPACE_MOVE    4
#define OP_WINDOW_TO_SPACE 5
#define OP_WINDOW_MOVE   6
#define OP_WINDOW_OPACITY 7
#define OP_WINDOW_LAYER  8
#define OP_WINDOW_STICKY 9
#define OP_WINDOW_SHADOW 10
#define OP_WINDOW_ORDER  11

// Function declarations
extern int SLSMainConnectionID(void);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref, uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern CGError SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);

// Global variables
static id g_dock_spaces;
static id g_dp_desktop_picture_manager;
static uint64_t g_add_space_fp;
static uint64_t g_remove_space_fp;
static uint64_t g_move_space_fp;
static bool g_macOSSequoia;
static pthread_t g_thread;
static int g_sockfd;
static char g_socket_path[256];

// Global base address
static uint64_t baseaddr;

// Utility functions
static inline uint64_t unpack_u64(const uint8_t *data) {
    uint64_t value;
    memcpy(&value, data, sizeof(uint64_t));
    return value;
}

static inline uint32_t unpack_u32(const uint8_t *data) {
    uint32_t value;
    memcpy(&value, data, sizeof(uint32_t));
    return value;
}

static inline int32_t unpack_i32(const uint8_t *data) {
    int32_t value;
    memcpy(&value, data, sizeof(int32_t));
    return value;
}

static inline float unpack_float(const uint8_t *data) {
    float value;
    memcpy(&value, data, sizeof(float));
    return value;
}

// Helper functions
static id space_for_display_with_id(CFStringRef display_uuid, uint64_t sid) {
    return ((id (*)(id, SEL, CFStringRef, uint64_t))objc_msgSend)(g_dock_spaces, @selector(spaceForDisplay:withID:), display_uuid, sid);
}

static id display_space_for_display_uuid(CFStringRef display_uuid) {
    return ((id (*)(id, SEL, CFStringRef))objc_msgSend)(g_dock_spaces, @selector(displaySpaceForDisplayUUID:), display_uuid);
}

static uint64_t get_space_id(id space) {
    return ((uint64_t (*)(id, SEL))objc_msgSend)(space, @selector(spaceID));
}

static void set_ivar_value(id obj, const char *ivar_name, id value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivar_name);
    if (ivar) {
        object_setIvar(obj, ivar, value);
    }
}

#ifdef __arm64__
// asm macros matching yabai exactly
#define asm__call_add_space(v0, v1, func) \
    __asm__("mov x0, %0\n" "mov x20, %1\n" : : "r"(v0), "r"(v1) : "x0", "x20"); \
    ((void (*)())(func))();

#define asm__call_move_space(v0, v1, v2, v3, func) \
    __asm__("mov x0, %0\n" "mov x1, %1\n" "mov x2, %2\n" "mov x20, %3\n" : : "r"(v0), "r"(v1), "r"(v2), "r"(v3) : "x0", "x1", "x2", "x20");

#endif

static int handle_handshake(int client_fd) {
    uint8_t version = 1;
    send(client_fd, &version, 1, 0);
    return 1;
}

static int handle_space_focus(const uint8_t *payload) {
    uint64_t sid = unpack_u64(payload);
    int cid = SLSMainConnectionID();
    
    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(cid, sid);
    if (!display_uuid) return 0;
    
    SLSManagedDisplaySetCurrentSpace(cid, display_uuid, sid);
    CFRelease(display_uuid);
    return 1;
}

static int handle_space_create(const uint8_t *payload) {
    if (!g_dock_spaces || !g_add_space_fp) return 0;
    
    uint64_t display_space_id = unpack_u64(payload);
    int cid = SLSMainConnectionID();
    
    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(cid, display_space_id);
    if (!display_uuid) return 0;
    
    __block uint64_t result = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id display_space = display_space_for_display_uuid(display_uuid);
        if (!display_space) return;
        
        id new_space = nil;
#ifdef __arm64__
        asm__call_add_space(new_space, display_space, g_add_space_fp);
#endif
        // Get the new space's ID
        result = get_space_id(new_space);
    });
    
    CFRelease(display_uuid);
    return result;
}

static int handle_space_destroy(const uint8_t *payload) {
    if (!g_dock_spaces || !g_remove_space_fp) return 0;
    
    uint64_t sid = unpack_u64(payload);
    int cid = SLSMainConnectionID();
    
    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(cid, sid);
    if (!display_uuid) return 0;
    
    // Don't destroy current space
    uint64_t active_sid = SLSManagedDisplayGetCurrentSpace(cid, display_uuid);
    if (sid == active_sid) {
        CFRelease(display_uuid);
        return 0;
    }
    
    id space = space_for_display_with_id(display_uuid, sid);
    id display_space = display_space_for_display_uuid(display_uuid);
    
    if (!space || !display_space) {
        CFRelease(display_uuid);
        return 0;
    }
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        typedef void (*remove_space_call)(id, id, id, uint64_t, uint64_t);
        ((remove_space_call)g_remove_space_fp)(space, display_space, g_dock_spaces, sid, sid);
    });
    
    CFRelease(display_uuid);
    return 1;
}

static int handle_space_move(const uint8_t *payload) {
    FILE *mf = fopen("/tmp/yabai.zig-sa-move.log", "a");
    if (mf) { fprintf(mf, "handle_space_move: dock=%p dppm=%p move_fp=0x%llx\n", g_dock_spaces, g_dp_desktop_picture_manager, g_move_space_fp); fflush(mf); }
    
    if (!g_dock_spaces || !g_dp_desktop_picture_manager || !g_move_space_fp) {
        if (mf) { fprintf(mf, "FAIL: missing globals\n"); fclose(mf); }
        return 0;
    }
    
    uint64_t source_space_id = unpack_u64(payload);
    uint64_t dest_space_id = unpack_u64(payload + 8);
    uint64_t source_prev_space_id = unpack_u64(payload + 16);
    int focus_dest_space = payload[24];
    
    if (mf) { fprintf(mf, "src=%llu dst=%llu prev=%llu focus=%d\n", source_space_id, dest_space_id, source_prev_space_id, focus_dest_space); fflush(mf); }
    
    int cid = SLSMainConnectionID();
    
    CFStringRef source_display_uuid = SLSCopyManagedDisplayForSpace(cid, source_space_id);
    if (!source_display_uuid) {
        if (mf) { fprintf(mf, "FAIL: no source display uuid\n"); fclose(mf); }
        return 0;
    }
    
    id source_space = space_for_display_with_id(source_display_uuid, source_space_id);
    id source_display_space = display_space_for_display_uuid(source_display_uuid);
    
    CFStringRef dest_display_uuid = SLSCopyManagedDisplayForSpace(cid, dest_space_id);
    if (!dest_display_uuid) {
        if (mf) { fprintf(mf, "FAIL: no dest display uuid\n"); fclose(mf); }
        CFRelease(source_display_uuid);
        return 0;
    }
    
    id dest_space = space_for_display_with_id(dest_display_uuid, dest_space_id);
    unsigned dest_display_id = ((unsigned (*)(id, SEL, id))objc_msgSend)(g_dock_spaces, @selector(displayIDForSpace:), dest_space);
    id dest_display_space = display_space_for_display_uuid(dest_display_uuid);
    
    if (mf) { fprintf(mf, "src_space=%p dst_space=%p dst_disp_id=%u\n", source_space, dest_space, dest_display_id); fflush(mf); }
    
    // Validate we found all required objects
    if (!source_space || !dest_space) {
        if (mf) { fprintf(mf, "FAIL: space objects not found\n"); fclose(mf); }
        CFRelease(source_display_uuid);
        CFRelease(dest_display_uuid);
        return 0;
    }
    
    // If source space is active and we have a prev space, switch to it first
    if (source_prev_space_id) {
        if (mf) { fprintf(mf, "switching away from active space first\n"); fflush(mf); }
        NSArray *ns_source_space = @[ @(source_space_id) ];
        NSArray *ns_dest_space = @[ @(source_prev_space_id) ];
        id new_source_space = space_for_display_with_id(source_display_uuid, source_prev_space_id);
        SLSShowSpaces(cid, (__bridge CFArrayRef)ns_dest_space);
        SLSHideSpaces(cid, (__bridge CFArrayRef)ns_source_space);
        SLSManagedDisplaySetCurrentSpace(cid, source_display_uuid, source_prev_space_id);
        set_ivar_value(source_display_space, "_currentSpace", new_source_space);
    }
    
    if (mf) { fprintf(mf, "calling asm__call_move_space\n"); fflush(mf); }
#ifdef __arm64__
    asm__call_move_space(source_space, dest_space, dest_display_uuid, g_dock_spaces, g_move_space_fp);
#endif
    if (mf) { fprintf(mf, "asm__call_move_space returned\n"); fflush(mf); }
    
    if (mf) { fprintf(mf, "calling dppm moveSpace:toDisplay:displayUUID:\n"); fflush(mf); }
    dispatch_sync(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, unsigned, CFStringRef))objc_msgSend)(
            g_dp_desktop_picture_manager, 
            @selector(moveSpace:toDisplay:displayUUID:), 
            source_space, dest_display_id, dest_display_uuid);
    });
    if (mf) { fprintf(mf, "dppm call returned\n"); fflush(mf); }
    
    if (focus_dest_space) {
        uint64_t new_source_space_id = SLSManagedDisplayGetCurrentSpace(cid, source_display_uuid);
        id new_source_space = space_for_display_with_id(source_display_uuid, new_source_space_id);
        set_ivar_value(source_display_space, "_currentSpace", new_source_space);
        
        NSArray *ns_dest_monitor_space = @[ @(dest_space_id) ];
        SLSHideSpaces(cid, (__bridge CFArrayRef)ns_dest_monitor_space);
        SLSManagedDisplaySetCurrentSpace(cid, dest_display_uuid, source_space_id);
        set_ivar_value(dest_display_space, "_currentSpace", source_space);
    }
    
    CFRelease(source_display_uuid);
    CFRelease(dest_display_uuid);
    if (mf) { fprintf(mf, "SUCCESS\n"); fclose(mf); }
    return 1;
}

static int handle_window_to_space(const uint8_t *payload) {
    uint64_t sid = unpack_u64(payload);
    uint32_t wid = unpack_u32(payload + 8);
    
    CFNumberRef wid_ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    if (!wid_ref) return 0;
    
    CFArrayRef window_list = CFArrayCreate(NULL, (const void **)&wid_ref, 1, &kCFTypeArrayCallBacks);
    CFRelease(wid_ref);
    if (!window_list) return 0;
    
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list, sid);
    CFRelease(window_list);
    return 1;
}

static int handle_window_move(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    int32_t x = unpack_i32(payload + 4);
    int32_t y = unpack_i32(payload + 8);
    CGPoint point = { .x = x, .y = y };
    return SLSMoveWindowWithGroup(SLSMainConnectionID(), wid, &point) == 0;
}

static int handle_window_opacity(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    float alpha = unpack_float(payload + 4);
    return SLSSetWindowAlpha(SLSMainConnectionID(), wid, alpha) == 0;
}

static int handle_window_layer(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    int32_t level = unpack_i32(payload + 4);
    return SLSSetWindowSubLevel(SLSMainConnectionID(), wid, level) == 0;
}

static int handle_window_sticky(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    int sticky = payload[4];
    uint64_t tags = 1ULL << 11;
    int cid = SLSMainConnectionID();
    return sticky
        ? SLSSetWindowTags(cid, wid, &tags, 64) == 0
        : SLSClearWindowTags(cid, wid, &tags, 64) == 0;
}

static int handle_window_shadow(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    int shadow = payload[4];
    uint64_t tags = 1ULL << 3;
    int cid = SLSMainConnectionID();
    return shadow
        ? SLSClearWindowTags(cid, wid, &tags, 64) == 0
        : SLSSetWindowTags(cid, wid, &tags, 64) == 0;
}

static int handle_window_order(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    int32_t order = unpack_i32(payload + 4);
    uint32_t rel_wid = unpack_u32(payload + 8);
    return SLSOrderWindow(SLSMainConnectionID(), wid, order, rel_wid) == 0;
}

// ============================================================================
// Server
// ============================================================================

static bool read_message(int sockfd, char *message, int *out_len) {
    int16_t bytes_to_read = 0;
    if (read(sockfd, &bytes_to_read, sizeof(int16_t)) != sizeof(int16_t)) return false;
    if (bytes_to_read <= 0 || bytes_to_read > 0x1000) return false;
    
    int bytes_read = 0;
    while (bytes_read < bytes_to_read) {
        int n = (int)read(sockfd, message + bytes_read, bytes_to_read - bytes_read);
        if (n <= 0) break;
        bytes_read += n;
    }
    *out_len = bytes_read;
    return bytes_read == bytes_to_read;
}

static void handle_client(int client_fd) {
    char message[0x1000];
    int len = 0;
    if (!read_message(client_fd, message, &len) || len < 1) return;
    
    uint8_t opcode = message[0];
    uint8_t *buf = (uint8_t *)message + 1;
    
    int success = 0;
    switch (opcode) {
        case OP_HANDSHAKE:
            handle_handshake(client_fd);
            return;
        case OP_SPACE_FOCUS:
            success = handle_space_focus(buf);
            break;
        case OP_SPACE_CREATE: {
            uint64_t result = handle_space_create(buf);
            send(client_fd, &result, 8, 0);
            return;
        }
        case OP_SPACE_DESTROY:
            success = handle_space_destroy(buf);
            break;
        case OP_SPACE_MOVE:
            success = handle_space_move(buf);
            break;
        case OP_WINDOW_TO_SPACE:
            success = handle_window_to_space(buf);
            break;
        case OP_WINDOW_MOVE:
            success = handle_window_move(buf);
            break;
        case OP_WINDOW_OPACITY:
            success = handle_window_opacity(buf);
            break;
        case OP_WINDOW_LAYER:
            success = handle_window_layer(buf);
            break;
        case OP_WINDOW_STICKY:
            success = handle_window_sticky(buf);
            break;
        case OP_WINDOW_SHADOW:
            success = handle_window_shadow(buf);
            break;
        case OP_WINDOW_ORDER:
            success = handle_window_order(buf);
            break;
    }
    
    uint8_t ack = success ? 0x01 : 0x00;
    send(client_fd, &ack, 1, 0);
}

static void *server_thread(void *arg) {
    (void)arg;
    for (;;) {
        int client_fd = accept(g_sockfd, NULL, 0);
        if (client_fd == -1) continue;
        handle_client(client_fd);
        shutdown(client_fd, SHUT_RDWR);
        close(client_fd);
    }
    return NULL;
}

// ============================================================================
// Initialization
// ============================================================================

#ifdef __arm64__
static uint64_t decode_adrp_add(uint64_t addr, uint64_t offset) {
    uint32_t adrp_instr = *(uint32_t *)addr;
    uint32_t immlo = (0x60000000 & adrp_instr) >> 29;
    uint32_t immhi = (0xffffe0 & adrp_instr) >> 3;
    int32_t value = (immhi | immlo) << 12;
    int64_t value_64 = value;
    
    uint32_t add_instr = *(uint32_t *)(addr + 4);
    uint64_t imm12 = (add_instr & 0x3ffc00) >> 10;
    if (add_instr & 0xc00000) imm12 <<= 12;
    
    return (offset & 0xfffffffffffff000) + value_64 + imm12;
}

// Patterns from yabai arm64_payload.m
const char *get_dock_spaces_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) {
        return "?8 ?? ?? ?? 08 ?? ?? 91 00 01 40 F9 E2 03 13 AA ?? ?? ?? 94 ?? ?? ?? ?? 08";
    } else if (os_version.majorVersion == 15) {
        return "?? 12 00 ?? ?? ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? ?? ?? ??";
    } else if (os_version.majorVersion == 14) {
        if (os_version.minorVersion > 0) {
            return "36 16 00 ?? D6 ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? 03 14 AA";
        }
        return "97 18 00 B0 F7 02 0F 91 E0 02 40 F9 E2 03 14 AA 1A 09 08 94 FD 03 1D AA 3C EF 07 94 F6 03 00 AA 00 01 00 B5 E0 02 40 F9 E2 03 14 AA 3B 0F 08 94 FD 03 1D AA 35 EF 07 94 F6 03 00 AA E0 00 00 B4 E0 03 15 AA E2 03 13 AA E3 03 16 AA F3 F3 07 94 E0 03 16 AA 1D EF 07 94 E0 03 14 AA";
    } else if (os_version.majorVersion == 13) {
        return "?? 17 00 ?? 73 ?? ?? 91 60 02 40 F9 E2 03 17 AA ?? ?? 07 94 FD 03 1D AA ?? ?? 07 94 E0 07 00 F9 ?? 16 00 ?? 00 ?? ?? F9 ?? ?? 07 94 02 00 80 D2 ?? ?? 07 94 E0 13 00 F9 60 02 40 F9 FC 1F 00 F9 E2 03 1C AA ?? ?? 07 94 FD 03 1D AA ?? ?? 07 94 F5 03 00 AA ?? 16 00 ?? ?? ?? ?? F9";
    } else if (os_version.majorVersion == 12) {
        return "55 21 00 ?? B5 ?? ?? 91 A0 02 40 F9 ?? 1F 00 ?? 01 ?? ?? F9 E2 03 1B AA ?? ?? 0C 94 FD 03 1D AA ?? ?? 0C 94 E0 13 00 F9 ?? 20 00 ?? 00 ?? ?? F9 ?? ?? 0C 94 E8 1F 00 ?? 13 ?? ?? F9 E1 03 13 AA 02 00 80 D2 ?? ?? 0C 94 E0 27 00 F9 A0 02 40 F9 08 20 00 ?? 01 ?? ?? F9";
    }

    return NULL;
}

const char *get_dppm_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) {
        return "?? 20 00 ?? 08 ?? ?? 91 00 01 40 F9 E2 03 16 AA E3 03 19 AA ?? ?? ?? 94";
    } else if (os_version.majorVersion == 15) {
        return "?? 0F 00 ?? ?? ?? ?? 91 ?? 0E 00 ?? ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??";
    } else if (os_version.majorVersion == 14) {
        if (os_version.minorVersion > 0) {
            return "?? 10 00 ?? ?? ?? ?? 91 ?? 0F 00 D0 ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??";
        }
        return "E0 20 00 90 00 ?? ?? 91 E1 03 13 AA ?? ?? 0C 94 73 2D 00 B4 E1 20 00 90 21 ?? ?? 91 00 00 80 D2 D9 13 0C 94 A8 1F 00 F0 00 79 43 F9 A2 38 0C 94 FD 03 1D AA 1C 1E 0C 94 F4 03 00 AA BF 7F 37 A9";
    } else if (os_version.majorVersion == 13) {
        return "00 20 00 D0 00 ?? ?? 91 E1 03 13 AA ?? ?? 0B 94 13 2E 00 B4 16 20 00 D0 D6 ?? ?? 91 00 00 80 D2 E1 03 16 AA ?? ?? 0B 94 E8 1E 00 D0 00 ?? ?? F9 ?? ?? 0B 94 FD 03 1D AA ?? ?? 0B 94 F4 03 00 AA";
    } else if (os_version.majorVersion == 12) {
        return "?? 21 00 ?? 00 ?? ?? 91 E1 03 13 AA ?? ?? 0C 94 ?? ?? 00 B4 ?? 20 00 ?? 00 ?? ?? F9 ?? ?? 00 ?? 19 ?? ?? F9 E1 03 19 AA ?? ?? 0C 94 FD 03 1D AA ?? ?? 0C 94 F4 03 00 AA ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ??";
    }

    return NULL;
}

const char *get_add_space_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) {
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03";
    } else if (os_version.majorVersion == 15) {
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03";
    } else if (os_version.majorVersion == 14) {
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F5 03";
    } else if (os_version.majorVersion == 13) {
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F5 03 14 AA F3 03 00 AA 89 E2 40 39 96 16 40 F9 C8 FE 7E D3 3F 05 00 71 A1 00 00 54 ?? 14 00 B5 C8 E2 7D 92 17 09 40 F9 ?? 00 00 14 ?? ?? 00 B5 C8 E2 7D 92 17 09 40 F9 ?? ?? 00 94 ?? ?? 00 B4 F8 06 00 F1 ?? 15 00 54 DA 0A 42 F2 E1 17 9F 1A E0 03 18 AA E2 03 16 AA ?? ?? ?? 97 ?? 14 00 B5 C8 0E 18 8B ?? ?? 00 94 F4 03 00 AA";
    } else if (os_version.majorVersion == 12) {
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F5 03 14 AA F3 03 00 AA 89 E2 40 39 96 16 40 F9 C8 FE 7E D3 3F 05 00 71 A1 00 00 54 ?? 14 00 B5 C8 E2 7D 92 17 09 40 F9 ?? 00 00 14 ?? ?? 00 B5 C8 E2 7D 92 17 09 40 F9 ?? ?? 00 94 ?? ?? 00 B4 F8 06 00 F1 ?? 15 00 54 DA 0A 42 F2 E1 17 9F 1A E0 03 18 AA E2 03 16 AA ?? ?? FD 97 ?? 14 00 B5 C8 0E 18 8B ?? ?? 00 94 F4 03 00 AA";
    }

    return NULL;
}

const char *get_remove_space_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) {
        return "7F 23 03 D5 FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? ?? A9 F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA F4 03 01 AA";
    } else if (os_version.majorVersion == 15) {
        return "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? AA";
    } else if (os_version.majorVersion == 14) {
        return "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? 97 FC 03 00 AA 08 FC 7E D3 ?? ?? 00 B5 88 E3 7D 92 00";
    } else if (os_version.majorVersion == 13) {
        return "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA F3 03 00 AA ?? ?? FD 97 FC 03 00 AA 08 FC 7E D3 ?? 20 00 B5 88 E3 7D 92 00 09 40 F9 1F 08 00 F1 2B 0F 00 54 F5 53 01 A9 C8 0A 00 B0 1F 20 03 D5 08 ?? ?? F9 68 02 08 8B 14 55 40 A9 48 0B 00 F0 1F 20 03 D5 00 ?? ?? F9 28 0A 00 B0 01 ?? ?? F9 F3 13 00 F9";
    } else if (os_version.majorVersion == 12) {
        return "7F 23 03 D5 FF 83 03 D1 FC 6F 08 A9 FA 67 09 A9 F8 5F 0A A9 F6 57 0B A9 F4 4F 0C A9 FD 7B 0D A9 FD 43 03 91 F7 03 03 AA F6 03 02 AA F5 03 01 AA F3 03 00 AA F4 03 01 AA ?? ?? FD 97 F4 03 00 AA 08 FC 7E D3 ?? ?? 00 B5 88 E2 7D 92 00 09 40 F9 1F 08 00 F1 ?? 0E 00 54 ?? ?? ?? ?? F5 ?? ?? ?? ?? ?? 00 ?? 1F 20 03 D5 08 ?? ?? F9 68 02 08 8B 14 69 40 A9 ?? 0A 00 ?? 1F 20 03 D5 00 ?? ?? F9 48 09 00 ?? 01 ?? ?? F9 F3 ?? 00 F9 E2 03 13 AA";
    }

    return NULL;
}

const char *get_move_space_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) {
        return "7F 23 03 D5 E3 03 1E AA ?? ?? ?? 97 FE 03 03 AA FD 7B ?? A9 FD ?? ?? 91 F6 03 14 AA";
    } else if (os_version.majorVersion == 15) {
        return "7F 23 03 D5 E3 03 1E AA ?? ?? FF 97 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FB 03 01 AA FA 03 00 AA ?? 13 00 ?? E8 ?? ?? F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA";
    } else if (os_version.majorVersion == 14) {
        return "7F 23 03 D5 FF C3 01 D1 E3 03 1E AA ?? ?? 00 94 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FA 03 01 AA FB 03 00 AA ?? ?? 00 ?? F7 ?? ?? 91 E8 02 40 F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA ?? 25 00 94 ?? ?? 00 B4 ?? 03 00 AA ?? 03 01 AA";
    } else if (os_version.majorVersion == 13) {
        if (os_version.minorVersion >= 3) {
            return "7F 23 03 D5 FF C3 01 D1 E3 03 1E AA EB 55 00 94 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FA 03 01 AA FB 03 00 AA 37 0B 00 D0 F7 82 19 91 E8 02 40 F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA 42 25 00 94 80 01 00 B4 F5 03 00 AA F3 03 01 AA C8 0B 00 90 08 A1 1D 91 08 01 40 39 1F 05 00 71 E1 00 00 54 62 58 00 94 ED 9C 01 94 1F 58 00 94 C7 00 00 14 14 00 80 52 CA 00 00 14 1A 01 00 B4 E8 02 40 F9 40 6B 68 F8 E1 03 16 AA";
        } else {
            return "7F 23 03 D5 E3 03 1E AA ?? ?? 00 94 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 ?? 03 14 AA ?? 03 02 AA FA 03 01 AA FB 03 00 AA ?? ?? 00 ?? ?? ?? ?? 91 ?? ?? 40 F9 ?? 68 68 F8 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 03 ?? AA ?? 03 ?? AA ?? ?? ?? ?? ?? ?? ?? ?? ?? 01 ?? ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? 00 ?? ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ??";
        }
    } else if (os_version.majorVersion == 12) {
        return "7F 23 03 D5 E3 03 1E AA ?? ?? 00 94 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 ?? 03 14 AA ?? 03 02 AA FA 03 01 AA FB 03 00 AA ?? 0A 00 ?? ?? ?? ?? 91 ?? ?? 40 F9 ?? 68 68 F8 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 03 ?? AA ?? 03 ?? AA ?? ?? ?? ?? ?? ?? ?? ?? ?? 01 ?? ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ?? ?? 00 ?? ?? ?? ?? 00 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? 00 ??";
    }

    return NULL;
}

// Search offsets from yabai arm64_payload.m
static uint64_t get_dock_spaces_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 26) {
        return 0x30000;
    } else if (os.majorVersion == 15) {
        return os.minorVersion >= 4 ? 0x1f0000 : 0x200000;
    } else if (os.majorVersion == 14) {
        return 0x114000;
    } else if (os.majorVersion == 13) {
        return 0x118000;
    } else if (os.majorVersion == 12) {
        return 0x8000;
    }

    return 0;
}

static uint64_t get_dppm_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 26) {
        return 0x70000;
    } else if (os.majorVersion == 15) {
        return 0x250000;
    } else if (os.majorVersion == 14) {
        return os.minorVersion > 0 ? 0x1d2000 : 0x9000;
    } else if (os.majorVersion == 13) {
        return 0x9000;
    } else if (os.majorVersion == 12) {
        return 0x7000;
    }

    return 0;
}

static uint64_t get_add_space_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 26) {
        return 0x250000;
    } else if (os.majorVersion == 15) {
        return 0x250000;
    } else if (os.majorVersion == 14) {
        return 0x1D0000;
    } else if (os.majorVersion == 13) {
        return 0x1E0000;
    } else if (os.majorVersion == 12) {
        return 0x220000;
    }

    return 0;
}

static uint64_t get_remove_space_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 26) {
        return 0x1e0000;
    } else if (os.majorVersion == 15) {
        return 0x1c0000;
    } else if (os.majorVersion == 14) {
        return 0x280000;
    } else if (os.majorVersion == 13) {
        return 0x2A0000;
    } else if (os.majorVersion == 12) {
        return 0x2E0000;
    }

    return 0;
}

static uint64_t get_move_space_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 26) {
        return 0x1c0000;
    } else if (os.majorVersion == 15) {
        return 0x1c0000;
    } else if (os.majorVersion == 14) {
        return 0x280000;
    } else if (os.majorVersion == 13) {
        return 0x290000;
    } else if (os.majorVersion == 12) {
        return 0x2D0000;
    }

    return 0;
}

#endif

static bool verify_os_version(void) {
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    g_macOSSequoia = (os.majorVersion == 15);
    return (os.majorVersion >= 12 && os.majorVersion <= 26);
}

static uint64_t static_base_address(void) {
    const struct mach_header_64 *header = (struct mach_header_64 *)_dyld_get_image_header(0);
    return (uint64_t)header;
}

static uint64_t image_slide(void) {
    return _dyld_get_image_vmaddr_slide(0);
}

static uint64_t hex_find_seq(uint64_t addr, const char *pattern) {
    if (!pattern) return 0;
    
    size_t pattern_len = strlen(pattern);
    if (pattern_len % 2 != 0) return 0;
    
    uint8_t *bytes = malloc(pattern_len / 2);
    if (!bytes) return 0;
    
    for (size_t i = 0; i < pattern_len; i += 2) {
        char byte_str[3] = {pattern[i], pattern[i+1], '\0'};
        bytes[i/2] = (uint8_t)strtol(byte_str, NULL, 16);
    }
    
    uint64_t result = 0;
    uint8_t *search_addr = (uint8_t *)addr;
    for (size_t i = 0; i < 0x100000; i++) {  // Search up to 1MB
        if (memcmp(search_addr + i, bytes, pattern_len / 2) == 0) {
            result = addr + i;
            break;
        }
    }
    
    free(bytes);
    return result;
}

static void discover_functions(void) {
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    
    // Initialize base address
    baseaddr = static_base_address() + image_slide();
    
    // Debug file - use fixed path that Dock can write to
    FILE *df = fopen("/tmp/yabai.zig-sa-discover.log", "w");
    if (df) { fprintf(df, "discover_functions: macOS %ld.%ld baseaddr=0x%llx\n", os.majorVersion, os.minorVersion, baseaddr); fflush(df); }
    
#ifdef __arm64__
#endif
    
    // Find dock_spaces global
    const char *dock_spaces_pattern = get_dock_spaces_pattern(os);
    uint64_t dock_spaces_addr = dock_spaces_pattern ? hex_find_seq(baseaddr + get_dock_spaces_offset(os), dock_spaces_pattern) : 0;
    if (dock_spaces_addr) {
        uint64_t offset = decode_adrp_add(dock_spaces_addr, dock_spaces_addr - baseaddr);
        g_dock_spaces = (__bridge id)(*(void **)(baseaddr + offset));
        if (df) { fprintf(df, "dock_spaces: addr=0x%llx offset=0x%llx obj=%p\n", dock_spaces_addr, offset, g_dock_spaces); fflush(df); }
    } else {
        if (df) { fprintf(df, "dock_spaces: NOT FOUND\n"); fflush(df); }
    }
    
    // Find dp_desktop_picture_manager global
    const char *dppm_pattern = get_dppm_pattern(os);
    uint64_t dppm_addr = dppm_pattern ? hex_find_seq(baseaddr + get_dppm_offset(os), dppm_pattern) : 0;
    if (dppm_addr) {
        uint64_t offset = decode_adrp_add(dppm_addr, dppm_addr - baseaddr);
        g_dp_desktop_picture_manager = (__bridge id)(*(void **)(baseaddr + offset));
        if (df) { fprintf(df, "dppm: addr=0x%llx offset=0x%llx obj=%p\n", dppm_addr, offset, g_dp_desktop_picture_manager); fflush(df); }
        // Sonoma workaround: try 8 bytes before if null
        if (!g_dp_desktop_picture_manager) {
            g_dp_desktop_picture_manager = (__bridge id)(*(void **)(baseaddr + offset - 0x8));
            if (df) { fprintf(df, "dppm (retry -8): obj=%p\n", g_dp_desktop_picture_manager); fflush(df); }
        }
    } else {
        if (df) { fprintf(df, "dppm: NOT FOUND\n"); fflush(df); }
    }
    
    // Find add_space function
    const char *add_space_pattern = get_add_space_pattern(os);
    uint64_t add_space_addr = add_space_pattern ? hex_find_seq(baseaddr + get_add_space_offset(os), add_space_pattern) : 0;
    if (add_space_addr) {
        g_add_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)add_space_addr, ptrauth_key_asia, 0);
        if (df) { fprintf(df, "add_space: addr=0x%llx fp=0x%llx\n", add_space_addr, g_add_space_fp); fflush(df); }
    } else {
        if (df) { fprintf(df, "add_space: NOT FOUND\n"); fflush(df); }
    }
    
    // Find remove_space function
    const char *remove_space_pattern = get_remove_space_pattern(os);
    uint64_t remove_space_addr = remove_space_pattern ? hex_find_seq(baseaddr + get_remove_space_offset(os), remove_space_pattern) : 0;
    if (remove_space_addr) {
        g_remove_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)remove_space_addr, ptrauth_key_asia, 0);
        if (df) { fprintf(df, "remove_space: addr=0x%llx fp=0x%llx\n", remove_space_addr, g_remove_space_fp); fflush(df); }
    } else {
        if (df) { fprintf(df, "remove_space: NOT FOUND\n"); fflush(df); }
    }
    
    // Find move_space function
    const char *move_space_pattern = get_move_space_pattern(os);
    uint64_t move_space_addr = move_space_pattern ? hex_find_seq(baseaddr + get_move_space_offset(os), move_space_pattern) : 0;
    if (move_space_addr) {
        g_move_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)move_space_addr, ptrauth_key_asia, 0);
        if (df) { fprintf(df, "move_space: addr=0x%llx fp=0x%llx\n", move_space_addr, g_move_space_fp); fflush(df); }
    } else {
        if (df) { fprintf(df, "move_space: NOT FOUND\n"); fflush(df); }
    }
    
    if (df) fclose(df);
}

__attribute__((constructor))
static void payload_init(void) {
    // Early debug - write to socket path directory which we know is accessible
    char logpath[256];
    snprintf(logpath, sizeof(logpath), "/tmp/yabai.zig-sa-debug-%d.log", getpid());
    FILE *ef = fopen(logpath, "w");
    // If that fails, try TMPDIR
    if (!ef) {
        const char *tmpdir = getenv("TMPDIR");
        if (tmpdir) {
            snprintf(logpath, sizeof(logpath), "%s/yabai.zig-sa-debug.log", tmpdir);
            ef = fopen(logpath, "w");
        }
    }
    if (ef) { fprintf(ef, "payload_init started pid=%d\n", getpid()); fflush(ef); }
    
    const char *user = getenv("USER");
    if (!user) {
        struct passwd *pw = getpwuid(getuid());
        user = pw ? pw->pw_name : "unknown";
    }
    
    if (ef) { fprintf(ef, "user=%s\n", user); fflush(ef); }
    
    snprintf(g_socket_path, sizeof(g_socket_path), SOCKET_PATH_FMT, user);
    unlink(g_socket_path);
    
    struct sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", g_socket_path);
    
    if ((g_sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) { if (ef) { fprintf(ef, "socket failed\n"); fclose(ef); } return; }
    if (bind(g_sockfd, (struct sockaddr *)&addr, sizeof(addr)) == -1) { close(g_sockfd); g_sockfd = -1; if (ef) { fprintf(ef, "bind failed\n"); fclose(ef); } return; }
    if (chmod(g_socket_path, 0600) != 0) { close(g_sockfd); g_sockfd = -1; if (ef) { fprintf(ef, "chmod failed\n"); fclose(ef); } return; }
    if (listen(g_sockfd, SOMAXCONN) == -1) { close(g_sockfd); g_sockfd = -1; if (ef) { fprintf(ef, "listen failed\n"); fclose(ef); } return; }
    
    if (ef) { fprintf(ef, "socket setup done at %s\n", g_socket_path); fflush(ef); }
    
    discover_functions();
    
    if (ef) { 
        fprintf(ef, "discover done: dock=%p dppm=%p add=0x%llx rm=0x%llx mv=0x%llx\n", 
            g_dock_spaces, g_dp_desktop_picture_manager, g_add_space_fp, g_remove_space_fp, g_move_space_fp); 
        fflush(ef); 
        fclose(ef); 
    }
    
    pthread_create(&g_thread, NULL, server_thread, NULL);
}

__attribute__((destructor))
static void payload_fini(void) {
    if (g_sockfd >= 0) {
        shutdown(g_sockfd, SHUT_RDWR);
        close(g_sockfd);
        g_sockfd = -1;
    }
    unlink(g_socket_path);
}
