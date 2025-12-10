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

static uint64_t static_base_address(void) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    return (uint64_t)header;
}

static uint64_t image_slide(void) {
    return _dyld_get_image_vmaddr_slide(0);
}

// ============================================================================
// Runtime Pattern Extraction System
// ============================================================================

// Bootstrap patterns - minimal hardcoded patterns to find initial entry points
// These are kept minimal and stable across versions
const char *bootstrap_dock_spaces_pattern = "?? ?? ?? ?? 08 ?? ?? 91 00 01 40 F9";  // Common across recent macOS
const char *bootstrap_dppm_pattern = "?? ?? ?? ?? 08 ?? ?? 91 00 01 40 F9";       // Similar structure

// Runtime extraction state
typedef struct {
    uint64_t base_addr;
    uint64_t slide;
    uint64_t text_start;
    uint64_t text_end;
} runtime_context_t;

static runtime_context_t g_runtime_ctx;

// Initialize runtime context
static bool init_runtime_context(void) {
    g_runtime_ctx.base_addr = static_base_address();
    g_runtime_ctx.slide = image_slide();

    // Find __TEXT segment bounds for scanning
    const struct mach_header_64 *header = (const struct mach_header_64 *)g_runtime_ctx.base_addr;
    struct load_command *cmd = (struct load_command *)(header + 1);

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                g_runtime_ctx.text_start = seg->vmaddr + g_runtime_ctx.slide;
                g_runtime_ctx.text_end = g_runtime_ctx.text_start + seg->vmsize;
                return true;
            }
        }
        cmd = (struct load_command *)((char *)cmd + cmd->cmdsize);
    }
    return false;
}

// Memory scanner for function discovery
static uint64_t scan_for_pattern(const char *pattern, uint64_t search_start, uint64_t search_end) {
    if (!pattern || search_end <= search_start) return 0;

    size_t pattern_len = strlen(pattern);
    if (pattern_len % 2 != 0) return 0;

    uint8_t *bytes = malloc(pattern_len / 2);
    if (!bytes) return 0;

    for (size_t i = 0; i < pattern_len; i += 2) {
        char byte_str[3] = {pattern[i], pattern[i+1], '\0'};
        bytes[i/2] = (uint8_t)strtol(byte_str, NULL, 16);
    }

    size_t byte_len = pattern_len / 2;
    uint8_t *search_ptr = (uint8_t *)search_start;

    for (uint64_t addr = search_start; addr < search_end - byte_len; addr += 1) {
        if (memcmp((void *)addr, bytes, byte_len) == 0) {
            free(bytes);
            return addr;
        }
    }

    free(bytes);
    return 0;
}

// Cross-reference analysis to find related functions
static uint64_t find_cross_reference(uint64_t target_addr, uint64_t search_start, uint64_t search_end) {
    // Look for ADRP + ADD patterns that reference our target
    uint64_t target_page = target_addr & ~0xFFFULL;

    for (uint64_t addr = search_start; addr < search_end - 8; addr += 4) {
        uint32_t instr1 = *(uint32_t *)addr;
        uint32_t instr2 = *(uint32_t *)(addr + 4);

        // Check for ADRP instruction
        if ((instr1 & 0x9F000000) == 0x90000000) {
            // Decode ADRP
            uint32_t immlo = (instr1 >> 29) & 0x3;
            uint32_t immhi = (instr1 >> 5) & 0x7FFFF;
            int64_t adrp_offset = ((immhi << 2) | immlo) << 12;
            int64_t page_addr = (addr & ~0xFFFULL) + adrp_offset;

            if (page_addr == target_page) {
                // Check if next instruction is ADD that gives us the target
                if ((instr2 & 0xFFC00000) == 0x91000000) {  // ADD instruction
                    uint32_t imm12 = (instr2 >> 10) & 0xFFF;
                    uint64_t computed_addr = page_addr + imm12;

                    if (computed_addr == target_addr) {
                        return addr;  // Found the referencing location
                    }
                }
            }
        }
    }
    return 0;
}

// Extract function address from ADRP+ADD sequence
static uint64_t extract_function_address(uint64_t pattern_addr) {
    if (!pattern_addr) return 0;

    uint32_t adrp_instr = *(uint32_t *)pattern_addr;
    uint32_t add_instr = *(uint32_t *)(pattern_addr + 4);

    // Decode ADRP
    uint32_t immlo = (adrp_instr >> 29) & 0x3;
    uint32_t immhi = (adrp_instr >> 5) & 0x7FFFF;
    int64_t adrp_offset = ((immhi << 2) | immlo) << 12;
    uint64_t page_base = (pattern_addr & ~0xFFFULL) + adrp_offset;

    // Decode ADD
    uint32_t imm12 = (add_instr >> 10) & 0xFFF;
    uint64_t final_addr = page_base + imm12;

    return final_addr;
}

// Advanced function discovery using cross-references
static uint64_t discover_function_by_cross_refs(uint64_t known_addr, const char *signature_pattern) {
    if (!known_addr) return 0;

    // Find all locations that reference our known address
    uint64_t xref_addr = find_cross_reference(known_addr, g_runtime_ctx.text_start, g_runtime_ctx.text_end);
    if (!xref_addr) return 0;

    // Look for the signature pattern near the cross-reference
    uint64_t search_start = xref_addr - 0x1000;  // Search 4KB before
    uint64_t search_end = xref_addr + 0x1000;    // Search 4KB after

    if (search_start < g_runtime_ctx.text_start) search_start = g_runtime_ctx.text_start;
    if (search_end > g_runtime_ctx.text_end) search_end = g_runtime_ctx.text_end;

    uint64_t pattern_addr = scan_for_pattern(signature_pattern, search_start, search_end);
    if (pattern_addr) {
        return extract_function_address(pattern_addr);
    }

    return 0;
}

// Bootstrap discovery using minimal patterns
static uint64_t bootstrap_find_global(const char *pattern, uint64_t search_offset) {
    uint64_t search_addr = g_runtime_ctx.base_addr + g_runtime_ctx.slide + search_offset;
    uint64_t pattern_addr = scan_for_pattern(pattern, search_addr, search_addr + 0x100000);

    if (pattern_addr) {
        return extract_function_address(pattern_addr);
    }
    return 0;
}

// Main runtime extraction function
static void discover_functions_runtime(void) {
    // IMMEDIATE DEBUG: This should appear if our function is called
    FILE *test_df = fopen("/tmp/yabai.zig-RUNTIME-EXTRACTION.log", "w");
    if (test_df) {
        fprintf(test_df, "RUNTIME EXTRACTION FUNCTION CALLED!\n");
        fclose(test_df);
    }
    // Initialize runtime context
    if (!init_runtime_context()) {
        FILE *df = fopen("/tmp/yabai.zig-sa-discover.log", "w");
        if (df) { fprintf(df, "Failed to initialize runtime context\n"); fclose(df); }
        return;
    }

    // Debug logging
    FILE *df = fopen("/tmp/yabai.zig-sa-discover.log", "w");
    if (df) {
        fprintf(df, "Runtime extraction: base=0x%llx slide=0x%llx text=0x%llx-0x%llx\n",
                g_runtime_ctx.base_addr, g_runtime_ctx.slide,
                g_runtime_ctx.text_start, g_runtime_ctx.text_end);
        fflush(df);
    }

    // Phase 1: Bootstrap with minimal patterns to find initial globals
    if (df) { fprintf(df, "Starting bootstrap phase...\n"); fflush(df); }
    
    uint64_t dock_spaces_addr = bootstrap_find_global(bootstrap_dock_spaces_pattern, 0x30000);
    if (dock_spaces_addr) {
        g_dock_spaces = (__bridge id)(*(void **)dock_spaces_addr);
        if (df) { fprintf(df, "BOOTSTRAP: Found dock_spaces at 0x%llx: %p\n", dock_spaces_addr, g_dock_spaces); fflush(df); }
    } else {
        if (df) { fprintf(df, "BOOTSTRAP: dock_spaces NOT FOUND\n"); fflush(df); }
    }

    uint64_t dppm_addr = bootstrap_find_global(bootstrap_dppm_pattern, 0x70000);
    if (dppm_addr) {
        g_dp_desktop_picture_manager = (__bridge id)(*(void **)dppm_addr);
        if (df) { fprintf(df, "BOOTSTRAP: Found dppm at 0x%llx: %p\n", dppm_addr, g_dp_desktop_picture_manager); fflush(df); }
    } else {
        if (df) { fprintf(df, "BOOTSTRAP: dppm NOT FOUND\n"); fflush(df); }
    }

    // Phase 2: Use cross-references to find function addresses
    // This is where the magic happens - we chain discovery from known globals

    // Find add_space by looking for functions that reference dock_spaces
    if (g_dock_spaces) {
        uint64_t dock_spaces_ptr = (uint64_t)g_dock_spaces;
        g_add_space_fp = discover_function_by_cross_refs(dock_spaces_ptr, "7F 23 03 D5 FF C3 01 D1");  // Function prologue
        if (g_add_space_fp) {
            g_add_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)g_add_space_fp, ptrauth_key_asia, 0);
            if (df) { fprintf(df, "Found add_space at 0x%llx\n", g_add_space_fp); fflush(df); }
        }
    }

    // Find remove_space by looking for functions that reference dock_spaces with different signature
    if (g_dock_spaces) {
        uint64_t dock_spaces_ptr = (uint64_t)g_dock_spaces;
        g_remove_space_fp = discover_function_by_cross_refs(dock_spaces_ptr, "7F 23 03 D5 FF ?? ?? D1");  // Different prologue
        if (g_remove_space_fp) {
            g_remove_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)g_remove_space_fp, ptrauth_key_asia, 0);
            if (df) { fprintf(df, "Found remove_space at 0x%llx\n", g_remove_space_fp); fflush(df); }
        }
    }

    // Find move_space by looking for functions that reference dppm
    if (g_dp_desktop_picture_manager) {
        uint64_t dppm_ptr = (uint64_t)g_dp_desktop_picture_manager;
        g_move_space_fp = discover_function_by_cross_refs(dppm_ptr, "7F 23 03 D5 E3 03 1E AA");
        if (g_move_space_fp) {
            g_move_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)g_move_space_fp, ptrauth_key_asia, 0);
            if (df) { fprintf(df, "Found move_space at 0x%llx\n", g_move_space_fp); fflush(df); }
        }
    }

    if (df) {
        fprintf(df, "Runtime discovery complete: dock=%p dppm=%p add=0x%llx rm=0x%llx mv=0x%llx\n",
                g_dock_spaces, g_dp_desktop_picture_manager, g_add_space_fp, g_remove_space_fp, g_move_space_fp);
        fclose(df);
    }
}
#endif

static bool verify_os_version(void) {
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    g_macOSSequoia = (os.majorVersion == 15);
    return (os.majorVersion >= 12 && os.majorVersion <= 26);
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
    
    discover_functions_runtime();
    
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
