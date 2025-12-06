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
#include <dlfcn.h>
#include <mach-o/dyld.h>
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
extern CGError SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);

// Globals discovered at init
static id g_dock_spaces = nil;
static uint64_t g_add_space_fp = 0;
static uint64_t g_remove_space_fp = 0;
static BOOL g_macOSSequoia = NO;

// Opcodes
enum {
    OP_HANDSHAKE = 0x01,
    OP_SPACE_FOCUS = 0x02,
    OP_SPACE_CREATE = 0x03,
    OP_SPACE_DESTROY = 0x04,
    OP_SPACE_MOVE = 0x05,
    OP_WINDOW_MOVE = 0x06,
    OP_WINDOW_OPACITY = 0x07,
    OP_WINDOW_LAYER = 0x09,
    OP_WINDOW_STICKY = 0x0a,
    OP_WINDOW_SHADOW = 0x0b,
    OP_WINDOW_ORDER = 0x10,
    OP_WINDOW_TO_SPACE = 0x13,
};

// Capability flags
enum {
    SA_CAP_SPACE_CREATE  = 1 << 0,
    SA_CAP_SPACE_DESTROY = 1 << 1,
};

static int g_sockfd = -1;
static char g_socket_path[256];
static volatile int g_running = 0;
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
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    return (uint64_t)header;
}

static uint64_t image_slide(void) {
    return _dyld_get_image_vmaddr_slide(0);
}

static uint64_t hex_find_seq(uint64_t baddr, const char *c_pattern) {
    if (!c_pattern) return 0;
    
    uint64_t addr = baddr;
    char buffer[3] = {0};
    char *pattern = (char *)c_pattern;
    
    while (*pattern) {
        while (*pattern == ' ') pattern++;
        if (!*pattern) break;
        
        if (pattern[0] == '?') {
            addr++;
            pattern += 2;
            continue;
        }
        
        buffer[0] = pattern[0];
        buffer[1] = pattern[1];
        uint8_t byte = (uint8_t)strtol(buffer, NULL, 16);
        
        if (*(uint8_t *)addr != byte) return 0;
        
        addr++;
        pattern += 2;
    }
    
    return baddr;
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

// arm64 patterns for macOS 15 (Sequoia)
static const char *get_dock_spaces_pattern_15(void) {
    return "?? 12 00 ?? ?? ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? ?? ?? ??";
}

static const char *get_add_space_pattern_15(void) {
    return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03";
}

static const char *get_remove_space_pattern_15(void) {
    return "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? AA";
}
#endif

// ============================================================================
// Space management helpers
// ============================================================================

static uint64_t get_space_id(id space) {
    if (!space) return 0;
    return ((uint64_t (*)(id, SEL))objc_msgSend)(space, @selector(spaceID));
}

static id display_space_for_display_uuid(CFStringRef display_uuid) {
    if (!g_dock_spaces || !display_uuid) return nil;
    
    SEL sel = g_macOSSequoia 
        ? @selector(currentSpaceForDisplayUUID:)
        : @selector(currentSpaceforDisplayUUID:);
    
    return ((id (*)(id, SEL, CFStringRef))objc_msgSend)(g_dock_spaces, sel, display_uuid);
}

// ============================================================================
// Command handlers
// ============================================================================

static void handle_handshake(int client_fd) {
    const char *version = "1.0.0";
    uint32_t attrib = 0;
    
    if (g_dock_spaces && g_add_space_fp) attrib |= SA_CAP_SPACE_CREATE;
    if (g_dock_spaces && g_remove_space_fp) attrib |= SA_CAP_SPACE_DESTROY;
    
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

static int handle_space_create(const uint8_t *payload) {
    if (!g_dock_spaces || !g_add_space_fp) return 0;
    
    uint64_t sid = unpack_u64(payload);
    int cid = SLSMainConnectionID();
    
    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(cid, sid);
    if (!display_uuid) return 0;
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        Class managed_space_class = g_macOSSequoia 
            ? objc_getClass("ManagedSpace")
            : objc_getClass("Dock.ManagedSpace");
        
        id new_space = [[managed_space_class alloc] init];
        id display_space = display_space_for_display_uuid(display_uuid);
        
#ifdef __arm64__
        // Call add_space function with: x0 = new_space, x20 = display_space
        __asm__("mov x0, %0\n"
                "mov x20, %1\n" 
                : 
                : "r"(new_space), "r"(display_space) 
                : "x0", "x20");
        ((void (*)())(g_add_space_fp))();
#endif
        
        CFRelease(display_uuid);
    });
    
    return 1;
}

static int handle_space_destroy(const uint8_t *payload) {
    if (!g_dock_spaces || !g_remove_space_fp) return 0;
    
    uint64_t sid = unpack_u64(payload);
    int cid = SLSMainConnectionID();
    
    CFStringRef display_ref = SLSCopyManagedDisplayForSpace(cid, sid);
    if (!display_ref) return 0;
    
    // Don't destroy current space
    uint64_t current_sid = SLSManagedDisplayGetCurrentSpace(cid, display_ref);
    if (sid == current_sid) {
        CFRelease(display_ref);
        return 0;
    }
    
    // Find the space object for this ID
    NSArray *spaces = ((NSArray *(*)(id, SEL))objc_msgSend)(g_dock_spaces, @selector(allSpaces));
    id target_space = nil;
    for (id space in spaces) {
        if (get_space_id(space) == sid) {
            target_space = space;
            break;
        }
    }
    
    if (!target_space) {
        CFRelease(display_ref);
        return 0;
    }
    
    dispatch_sync(dispatch_get_main_queue(), ^{
#ifdef __arm64__
        // Call remove_space function with: x0 = target_space
        __asm__("mov x0, %0\n" : : "r"(target_space) : "x0");
        ((void (*)())(g_remove_space_fp))();
#endif
    });
    
    CFRelease(display_ref);
    return 1;
}

static int handle_window_to_space(const uint8_t *payload) {
    uint64_t sid = unpack_u64(payload);
    uint32_t wid = unpack_u32(payload + 8);
    int cid = SLSMainConnectionID();
    
    CFNumberRef wid_ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    if (!wid_ref) return 0;
    
    CFArrayRef window_list = CFArrayCreate(NULL, (const void **)&wid_ref, 1, &kCFTypeArrayCallBacks);
    CFRelease(wid_ref);
    if (!window_list) return 0;
    
    SLSMoveWindowsToManagedSpace(cid, window_list, sid);
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
    
    if (sticky) {
        return SLSSetWindowTags(cid, wid, &tags, 64) == 0;
    } else {
        return SLSClearWindowTags(cid, wid, &tags, 64) == 0;
    }
}

static int handle_window_shadow(const uint8_t *payload) {
    uint32_t wid = unpack_u32(payload);
    int shadow = payload[4];
    uint64_t tags = 1ULL << 3;
    int cid = SLSMainConnectionID();
    
    if (shadow) {
        return SLSClearWindowTags(cid, wid, &tags, 64) == 0;
    } else {
        return SLSSetWindowTags(cid, wid, &tags, 64) == 0;
    }
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

static void handle_client(int client_fd) {
    uint8_t header[3];
    ssize_t n = recv(client_fd, header, 3, MSG_WAITALL);
    if (n != 3) return;
    
    int16_t len = *(int16_t *)header;
    uint8_t opcode = header[2];
    
    uint8_t buf[256];
    if (len > 1 && len - 1 <= sizeof(buf)) {
        n = recv(client_fd, buf, len - 1, MSG_WAITALL);
        if (n != len - 1) return;
    }
    
    int success = 0;
    switch (opcode) {
        case OP_HANDSHAKE:
            handle_handshake(client_fd);
            return;
        case OP_SPACE_FOCUS:
            success = handle_space_focus(buf);
            break;
        case OP_SPACE_CREATE:
            success = handle_space_create(buf);
            break;
        case OP_SPACE_DESTROY:
            success = handle_space_destroy(buf);
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
    while (g_running) {
        int client_fd = accept(g_sockfd, NULL, NULL);
        if (client_fd < 0) {
            if (!g_running) break;
            continue;
        }
        handle_client(client_fd);
        close(client_fd);
    }
    return NULL;
}

// ============================================================================
// Initialization
// ============================================================================

static void discover_functions(void) {
    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSLog(@"[yabai.zig-sa] macOS %ld.%ld.%ld", os.majorVersion, os.minorVersion, os.patchVersion);
    
#ifdef __arm64__
    if (os.majorVersion < 15) {
        NSLog(@"[yabai.zig-sa] requires macOS 15+");
        return;
    }
    
    g_macOSSequoia = YES;
    uint64_t baseaddr = static_base_address() + image_slide();
    NSLog(@"[yabai.zig-sa] Dock base: 0x%llx", baseaddr);
    
    // Find dock_spaces
    uint64_t dock_spaces_addr = 0;
    for (uint64_t off = 0x1f0000; off <= 0x250000 && !dock_spaces_addr; off += 0x10000) {
        dock_spaces_addr = hex_find_seq(baseaddr + off, get_dock_spaces_pattern_15());
    }
    
    if (dock_spaces_addr) {
        uint64_t dock_spaces_offset = decode_adrp_add(dock_spaces_addr, dock_spaces_addr - baseaddr);
        g_dock_spaces = [(*(id *)(baseaddr + dock_spaces_offset)) retain];
        NSLog(@"[yabai.zig-sa] dock_spaces: %p", g_dock_spaces);
    } else {
        NSLog(@"[yabai.zig-sa] dock_spaces not found!");
    }
    
    // Find add_space
    for (uint64_t off = 0x250000; off <= 0x2a0000 && !g_add_space_fp; off += 0x10000) {
        uint64_t addr = hex_find_seq(baseaddr + off, get_add_space_pattern_15());
        if (addr) {
            g_add_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)addr, ptrauth_key_asia, 0);
            NSLog(@"[yabai.zig-sa] add_space: 0x%llx", addr);
        }
    }
    if (!g_add_space_fp) NSLog(@"[yabai.zig-sa] add_space not found!");
    
    // Find remove_space  
    for (uint64_t off = 0x1c0000; off <= 0x200000 && !g_remove_space_fp; off += 0x10000) {
        uint64_t addr = hex_find_seq(baseaddr + off, get_remove_space_pattern_15());
        if (addr) {
            g_remove_space_fp = (uint64_t)ptrauth_sign_unauthenticated((void *)addr, ptrauth_key_asia, 0);
            NSLog(@"[yabai.zig-sa] remove_space: 0x%llx", addr);
        }
    }
    if (!g_remove_space_fp) NSLog(@"[yabai.zig-sa] remove_space not found!");
#endif
}

__attribute__((constructor))
static void payload_init(void) {
    NSLog(@"[yabai.zig-sa] initializing...");
    
    discover_functions();
    
    const char *user = getenv("USER");
    if (!user) {
        static char uid_buf[32];
        snprintf(uid_buf, sizeof(uid_buf), "%d", getuid());
        user = uid_buf;
    }
    
    snprintf(g_socket_path, sizeof(g_socket_path), SOCKET_PATH_FMT, user);
    unlink(g_socket_path);
    
    g_sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_sockfd < 0) return;
    
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, g_socket_path, sizeof(addr.sun_path) - 1);
    
    if (bind(g_sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(g_sockfd);
        g_sockfd = -1;
        return;
    }
    
    if (listen(g_sockfd, 5) < 0) {
        close(g_sockfd);
        g_sockfd = -1;
        return;
    }
    
    chmod(g_socket_path, 0600);
    g_running = 1;
    pthread_create(&g_thread, NULL, server_thread, NULL);
    
    NSLog(@"[yabai.zig-sa] ready on %s (spaces=%d)", g_socket_path, g_dock_spaces && g_add_space_fp);
}

__attribute__((destructor))
static void payload_fini(void) {
    g_running = 0;
    if (g_sockfd >= 0) {
        close(g_sockfd);
        g_sockfd = -1;
    }
    unlink(g_socket_path);
}
