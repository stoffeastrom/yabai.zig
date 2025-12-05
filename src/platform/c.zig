// Unified C imports for yabai.zig
// Note: We avoid Objective-C headers (Cocoa.h) as zig can't parse them
pub const c = @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("CoreServices/CoreServices.h");
    @cInclude("CoreVideo/CoreVideo.h");
    @cInclude("mach/mach_time.h");
    @cInclude("mach-o/dyld.h");
    @cInclude("mach-o/swap.h");
    @cInclude("bootstrap.h");
    @cInclude("stdio.h");
    @cInclude("stddef.h");
    @cInclude("stdlib.h");
    @cInclude("stdint.h");
    @cInclude("string.h");
    @cInclude("dirent.h");
    @cInclude("stdbool.h");
    @cInclude("assert.h");
    @cInclude("fcntl.h");
    @cInclude("regex.h");
    @cInclude("execinfo.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("poll.h");
    @cInclude("pthread.h");
    @cInclude("pwd.h");
    @cInclude("spawn.h");
    @cInclude("libproc.h");
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
});

// Private AX API to get CGWindowID from AXUIElement
pub extern fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) c.AXError;

pub const pid_t = c.pid_t;
pub const mach_port_t = c.mach_port_t;
pub const CGError = c.CGError;
pub const CGRect = c.CGRect;
pub const CGPoint = c.CGPoint;
pub const CGAffineTransform = c.CGAffineTransform;
pub const CFStringRef = c.CFStringRef;
pub const CFTypeRef = c.CFTypeRef;
pub const CFArrayRef = c.CFArrayRef;
pub const CFDictionaryRef = c.CFDictionaryRef;
pub const CFUUIDRef = c.CFUUIDRef;
pub const CFDataRef = c.CFDataRef;
pub const CGContextRef = c.CGContextRef;
pub const AXUIElementRef = c.AXUIElementRef;
pub const AXError = c.AXError;
pub const ProcessSerialNumber = c.ProcessSerialNumber;
pub const OSStatus = c.OSStatus;
pub const Boolean = c.Boolean;
pub const getpid = c.getpid;

// NSApplicationLoad is needed to initialize the application
pub extern fn NSApplicationLoad() c.Boolean;

/// Create a CFString from a Zig string literal (must be null-terminated)
pub fn cfstr(comptime s: [:0]const u8) CFStringRef {
    return c.CFStringCreateWithCString(null, s.ptr, c.kCFStringEncodingUTF8);
}
