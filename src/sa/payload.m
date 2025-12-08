// SA Payload - Scripting Addition dylib injected into Dock.app
// Based on yabai's osax/payload.m - uses pattern matching to find Dock internal functions

#include <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <pwd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <objc/runtime.h>
#include <objc/message.h>

#ifdef __arm64__
#include <ptrauth.h>
#endif

#define SOCKET_PATH_FMT "/tmp/yabai.zig-sa_%s.socket"

// SkyLight private APIs
extern int SLSMainConnectionID(void);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref, uint64_t sid);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern CGError SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);

// Globals discovered at init
static id g_dock_spaces = nil;
static id g_dp_desktop_picture_manager = nil;
static uint64_t g_add_space_fp = 0;
static uint64_t g_remove_space_fp = 0;
static uint64_t g_move_space_fp = 0;
static BOOL g_macOSSequoia = NO;

// Opcodes (must match client.zig)
enum {
    OP_HANDSHAKE      = 0x01,
    OP_SPACE_FOCUS    = 0x02,
    OP_SPACE_CREATE   = 0x03,
    OP_SPACE_DESTROY  = 0x04,
    OP_SPACE_MOVE     = 0x05,
    OP_WINDOW_MOVE    = 0x06,
    OP_WINDOW_OPACITY = 0x07,
    OP_WINDOW_LAYER   = 0x09,
    OP_WINDOW_STICKY  = 0x0a,
    OP_WINDOW_SHADOW  = 0x0b,
    OP_WINDOW_ORDER   = 0x10,
    OP_WINDOW_TO_SPACE = 0x13,
};

// Capability flags for handshake
enum {
    SA_CAP_SPACE_CREATE  = 1 << 0,
    SA_CAP_SPACE_DESTROY = 1 << 1,
    SA_CAP_SPACE_MOVE    = 1 << 2,
};

static int g_sockfd = -1;
static char g_socket_path[256];
static pthread_t g_thread;

// Unpack helpers
#define unpack_u32(buf) (*(uint32_t*)(buf))
#define unpack_u64(buf) (*(uint64_t*)(buf))
#define unpack_i32(buf) (*(int32_t*)(buf))
#define unpack_float(buf) (*(float*)(buf))

// ============================================================================
// Pattern matching (from yabai osax)
// ============================================================================

static uint64_t static_base_address(void) {
    // Use _dyld_get_image_header instead of deprecated getsegbyname
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    const uint8_t *ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                return seg->vmaddr;
            }
        }
        ptr += lc->cmdsize;
    }
    return 0;
}

static uint64_t image_slide(void) {
    char path[1024];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static uint64_t hex_find_seq(uint64_t baddr, const char *c_pattern) {
    if (!baddr || !c_pattern) return 0;
    
    uint64_t addr = baddr;
    uint64_t pattern_length = (strlen(c_pattern) + 1) / 3;
    char buffer_a[pattern_length];
    char buffer_b[pattern_length];
    memset(buffer_a, 0, sizeof(buffer_a));
    memset(buffer_b, 0, sizeof(buffer_b));
    
    // Parse pattern into bytes (buffer_a) and mask (buffer_b, 1=wildcard)
    char *pattern = (char *)c_pattern + 1;
    for (int i = 0; i < pattern_length; ++i) {
        char c = pattern[-1];
        if (c == '?') {
            buffer_b[i] = 1;
        } else {
            int temp = c <= '9' ? 0 : 9;
            temp = (temp + c) << 0x4;
            c = pattern[0];
            int temp2 = c <= '9' ? 0xd0 : 0xc9;
            buffer_a[i] = temp2 + c + temp;
        }
        pattern += 3;
    }
    
    // Search up to 0x1286a0 bytes from start
loop:
    for (int counter = 0; counter < pattern_length; ++counter) {
        if ((buffer_b[counter] == 0) && (((char *)addr)[counter] != buffer_a[counter])) {
            addr = (uint64_t)((char *)addr + 1);
            if (addr - baddr < 0x1286a0) {
                goto loop;
            }
            return 0;
        }
    }
    
    return addr;
}

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

// Patterns from yabai arm64_payload.m for macOS 15 (Sequoia)
static const char *pattern_dock_spaces_15 = "?? 12 00 ?? ?? ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? ?? ?? ??";
static const char *pattern_dppm_15 = "?? 0F 00 ?? ?? ?? ?? 91 ?? 0E 00 ?? ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??";
static const char *pattern_add_space_15 = "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03";
static const char *pattern_remove_space_15 = "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? AA";
static const char *pattern_move_space_15 = "7F 23 03 D5 E3 03 1E AA ?? ?? FF 97 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FB 03 01 AA FA 03 00 AA ?? 13 00 ?? E8 ?? ?? F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA";

// Search offsets from yabai arm64_payload.m
static uint64_t get_dock_spaces_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 15) return os.minorVersion >= 4 ? 0x1f0000 : 0x200000;
    return 0;
}

static uint64_t get_dppm_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 15) return 0x250000;
    return 0;
}

static uint64_t get_add_space_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 15) return 0x250000;
    return 0;
}

static uint64_t get_remove_space_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 15) return 0x1c0000;
    return 0;
}

static uint64_t get_move_space_offset(NSOperatingSystemVersion os) {
    if (os.majorVersion == 15) return 0x1c0000;
    return 0;
}

// asm macros matching yabai exactly
#define asm__call_add_space(v0, v1, func) \
    __asm__("mov x0, %0\n" "mov x20, %1\n" : : "r"(v0), "r"(v1) : "x0", "x20"); \
    ((void (*)())(func))();

#define asm__call_move_space(v0, v1, v2, v3, func) \
    __asm__("mov x0, %0\n" "mov x1, %1\n" "mov x2, %2\n" "mov x20, %3\n" : : "r"(v0), "r"(v1), "r"(v2), "r"(v3) : "x0", "x1", "x2", "x20"); \
    ((void (*)())(func))();

#endif

// ============================================================================
// Space management helpers
// ============================================================================

static uint64_t get_space_id(id space) {
    if (!space) return 0;
    return ((uint64_t (*)(id, SEL))objc_msgSend)(space, @selector(spid));
}

static id get_ivar_value(id instance, const char *name) {
    id result = nil;
    object_getInstanceVariable(instance, name, (void **)&result);
    return result;
}

static void set_ivar_value(id instance, const char *name, id value) {
    object_setInstanceVariable(instance, name, value);
}

static id space_for_display_with_id(CFStringRef display_uuid, uint64_t space_id) {
    NSArray *spaces = ((NSArray *(*)(id, SEL, CFStringRef))objc_msgSend)(
        g_dock_spaces, @selector(spacesForDisplay:), display_uuid);
    for (id space in spaces) {
        if (get_space_id(space) == space_id) {
            return space;
        }
    }
    return nil;
}

static id display_space_for_display_uuid(CFStringRef display_uuid) {
    if (!g_dock_spaces || !display_uuid) return nil;
    
    NSArray *display_spaces = get_ivar_value(g_dock_spaces, "_displaySpaces");
    if (!display_spaces) return nil;
    
    for (id display_space in display_spaces) {
        id current_space = get_ivar_value(display_space, "_currentSpace");
        uint64_t sid = get_space_id(current_space);
        CFStringRef uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), sid);
        if (uuid) {
            bool match = CFEqual(uuid, display_uuid);
            CFRelease(uuid);
            if (match) return display_space;
        }
    }
    return nil;
}

static id display_space_for_space_with_id(uint64_t space_id) {
    NSArray *display_spaces = get_ivar_value(g_dock_spaces, "_displaySpaces");
    if (!display_spaces) return nil;
    
    for (id display_space in display_spaces) {
        id current_space = get_ivar_value(display_space, "_currentSpace");
        if (get_space_id(current_space) == space_id) {
            return display_space;
        }
    }
    return nil;
}

// ============================================================================
// Command handlers
// ============================================================================

static void handle_handshake(int client_fd) {
    const char *version = "1.0.0";
    uint32_t attrib = 0;
    
    if (g_dock_spaces && g_add_space_fp) attrib |= SA_CAP_SPACE_CREATE;
    if (g_dock_spaces && g_remove_space_fp) attrib |= SA_CAP_SPACE_DESTROY;
    if (g_dock_spaces && g_dp_desktop_picture_manager && g_move_space_fp) attrib |= SA_CAP_SPACE_MOVE;
    
    char response[64];
    size_t len = strlen(version);
    memcpy(response, version, len);
    response[len] = 0;
    memcpy(response + len + 1, &attrib, 4);
    response[len + 5] = '\n';
    
    send(client_fd, response, len + 6, 0);
}

static int handle_space_focus(const uint8_t *payload) {
    uint64_t sid = unpack_u64(payload);
    int cid = SLSMainConnectionID();
    
    CFStringRef display_ref = SLSCopyManagedDisplayForSpace(cid, sid);
    if (!display_ref) return 0;
    
    SLSManagedDisplaySetCurrentSpace(cid, display_ref, sid);
    CFRelease(display_ref);
    return 1;
}

static uint64_t handle_space_create(const uint8_t *payload) {
    if (!g_dock_spaces || !g_add_space_fp) return 0;
    
    uint64_t sid = unpack_u64(payload);
    CFStringRef __block display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), sid);
    if (!display_uuid) return 0;
    
    __block uint64_t result = 0;
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        id new_space = g_macOSSequoia
            ? [[objc_getClass("ManagedSpace") alloc] init]
            : [[objc_getClass("Dock.ManagedSpace") alloc] init];
        
        id display_space = display_space_for_display_uuid(display_uuid);
        if (new_space && display_space) {
#ifdef __arm64__
            asm__call_add_space(new_space, display_space, g_add_space_fp);
#endif
            // Get the new space's ID
            result = get_space_id(new_space);
        }
        CFRelease(display_uuid);
    });
    
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
        set_ivar_value(source_display_space, "_currentSpace", [new_source_space retain]);
        [ns_dest_space release];
        [ns_source_space release];
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
        set_ivar_value(source_display_space, "_currentSpace", [new_source_space retain]);
        
        NSArray *ns_dest_monitor_space = @[ @(dest_space_id) ];
        SLSHideSpaces(cid, (__bridge CFArrayRef)ns_dest_monitor_space);
        SLSManagedDisplaySetCurrentSpace(cid, dest_display_uuid, source_space_id);
        set_ivar_value(dest_display_space, "_currentSpace", [source_space retain]);
        [ns_dest_monitor_space release];
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

static void discover_functions(void) {
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    
    // Debug file - use fixed path that Dock can write to
    FILE *df = fopen("/tmp/yabai.zig-sa-discover.log", "w");
    if (df) { fprintf(df, "discover_functions: macOS %ld.%ld\n", os.majorVersion, os.minorVersion); fflush(df); }
    
#ifdef __arm64__
    if (os.majorVersion < 15) {
        if (df) { fprintf(df, "unsupported macOS version\n"); fclose(df); }
        return;
    }
    
    g_macOSSequoia = YES;
    uint64_t baseaddr = static_base_address() + image_slide();
    if (df) { fprintf(df, "baseaddr: 0x%llx\n", baseaddr); fflush(df); }
    
    // Find dock_spaces global
    uint64_t dock_spaces_addr = hex_find_seq(baseaddr + get_dock_spaces_offset(os), pattern_dock_spaces_15);
    if (dock_spaces_addr) {
        uint64_t offset = decode_adrp_add(dock_spaces_addr, dock_spaces_addr - baseaddr);
        g_dock_spaces = [(*(id *)(baseaddr + offset)) retain];
        if (df) { fprintf(df, "dock_spaces: addr=0x%llx offset=0x%llx obj=%p\n", dock_spaces_addr, offset, g_dock_spaces); fflush(df); }
    } else {
        if (df) { fprintf(df, "dock_spaces: NOT FOUND\n"); fflush(df); }
    }
    
    // Find dp_desktop_picture_manager global
    uint64_t dppm_addr = hex_find_seq(baseaddr + get_dppm_offset(os), pattern_dppm_15);
    if (dppm_addr) {
        uint64_t offset = decode_adrp_add(dppm_addr, dppm_addr - baseaddr);
        g_dp_desktop_picture_manager = [(*(id *)(baseaddr + offset)) retain];
        if (df) { fprintf(df, "dppm: addr=0x%llx offset=0x%llx obj=%p\n", dppm_addr, offset, g_dp_desktop_picture_manager); fflush(df); }
        // Sonoma workaround: try 8 bytes before if null
        if (!g_dp_desktop_picture_manager) {
            g_dp_desktop_picture_manager = [(*(id *)(baseaddr + offset - 0x8)) retain];
            if (df) { fprintf(df, "dppm (retry -8): obj=%p\n", g_dp_desktop_picture_manager); fflush(df); }
        }
    } else {
        if (df) { fprintf(df, "dppm: NOT FOUND\n"); fflush(df); }
    }
    
    // Find add_space function
    uint64_t add_space_addr = hex_find_seq(baseaddr + get_add_space_offset(os), pattern_add_space_15);
    if (add_space_addr) {
        g_add_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)add_space_addr, ptrauth_key_asia, 0);
        if (df) { fprintf(df, "add_space: addr=0x%llx fp=0x%llx\n", add_space_addr, g_add_space_fp); fflush(df); }
    } else {
        if (df) { fprintf(df, "add_space: NOT FOUND\n"); fflush(df); }
    }
    
    // Find remove_space function
    uint64_t remove_space_addr = hex_find_seq(baseaddr + get_remove_space_offset(os), pattern_remove_space_15);
    if (remove_space_addr) {
        g_remove_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)remove_space_addr, ptrauth_key_asia, 0);
        if (df) { fprintf(df, "remove_space: addr=0x%llx fp=0x%llx\n", remove_space_addr, g_remove_space_fp); fflush(df); }
    } else {
        if (df) { fprintf(df, "remove_space: NOT FOUND\n"); fflush(df); }
    }
    
    // Find move_space function
    uint64_t move_space_addr = hex_find_seq(baseaddr + get_move_space_offset(os), pattern_move_space_15);
    if (move_space_addr) {
        g_move_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)move_space_addr, ptrauth_key_asia, 0);
        if (df) { fprintf(df, "move_space: addr=0x%llx fp=0x%llx\n", move_space_addr, g_move_space_fp); fflush(df); }
    } else {
        if (df) { fprintf(df, "move_space: NOT FOUND\n"); fflush(df); }
    }
    
    if (df) fclose(df);
#endif
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
