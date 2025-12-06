# Scripting Addition (SA)

The SA enables privileged window management operations that require injection into Dock.app:
- Move windows between spaces
- Create/destroy spaces (not yet implemented)
- Focus spaces directly
- Window operations (opacity, layer, sticky, shadow, ordering)

## Architecture

```
yabai.zig (client)  <--unix socket-->  payload.m (in Dock)
                                            |
     --load-sa                              v
         |                           SkyLight.framework
         v                           (private APIs)
    loader.m
         |
         v
    Dock.app (injection via Mach APIs)
```

## Files

| File | Built With | Output | Purpose |
|------|------------|--------|---------|
| `src/sa/payload.m` | clang (arm64e) | `zig-out/lib/libyabai-sa.dylib` | Dylib injected into Dock |
| `src/sa/loader.m` | clang (arm64e + x86_64) | `zig-out/bin/yabai-sa-loader` | Injects payload into Dock |
| `src/sa/client.zig` | zig | (part of main binary) | Client to talk to injected payload |
| `src/sa/injector.zig` | zig | (unused) | Was Zig injection attempt |

## Why arm64e?

Dock.app runs as arm64e on Apple Silicon. The payload dylib must also be arm64e for:
1. Constructors (`__attribute__((constructor))`) to execute on dlopen
2. Proper PAC (Pointer Authentication) compatibility

The loader needs arm64e to use PAC intrinsics (`ptrauth_sign_unauthenticated`) for thread state setup.

Zig doesn't support arm64e, so we use clang for SA components.

## Build

Everything builds with `zig build`:

```bash
zig build          # Builds main binary + SA loader + SA payload
zig build sign     # Also codesigns for accessibility
```

Build commands in `build.zig`:
- Payload: `xcrun clang src/sa/payload.m -shared -arch arm64e -framework SkyLight ...`
- Loader: `xcrun clang src/sa/loader.m -arch arm64e -arch x86_64 ...`

## Usage

### Load SA (requires sudo + SIP debugging disabled)

```bash
sudo ./zig-out/bin/yabai.zig --load-sa
```

This:
1. Copies payload to `/Library/ScriptingAdditions/yabai.zig.osax/Contents/MacOS/payload`
2. Finds Dock PID
3. Runs `yabai-sa-loader <pid> <payload_path>`
4. Loader injects shellcode into Dock that calls `dlopen(payload)`
5. Payload constructor creates socket at `/tmp/yabai.zig-sa_{USER}.socket`

### Unload SA

```bash
sudo ./zig-out/bin/yabai.zig --unload-sa
killall Dock  # Required to fully unload
```

### Passwordless sudo

```bash
sudo ./zig-out/bin/yabai.zig --install-sudoers
```

Creates `/etc/sudoers.d/yabai-zig` with sha256-verified entry for `--load-sa`.

## Protocol

Unix socket at `/tmp/yabai.zig-sa_{USER}.socket`

### Message format

```
| length (2 bytes, little-endian) | opcode (1 byte) | payload (variable) |
```

Length includes opcode but not itself.

### Opcodes

| Code | Name | Payload | Response |
|------|------|---------|----------|
| 0x01 | handshake | (none) | version + attrib |
| 0x02 | space_focus | sid(8) | ack |
| 0x06 | window_move | wid(4) + x(4) + y(4) | ack |
| 0x07 | window_opacity | wid(4) + alpha(4) | ack |
| 0x09 | window_layer | wid(4) + level(4) | ack |
| 0x0a | window_sticky | wid(4) + bool(1) | ack |
| 0x0b | window_shadow | wid(4) + bool(1) | ack |
| 0x10 | window_order | wid_a(4) + order(4) + wid_b(4) | ack |
| 0x13 | window_to_space | sid(8) + wid(4) | ack |

### Response

- Handshake: `version\0` + attrib(4) + `\n`
- Others: 1 byte (0x01 = success, 0x00 = fail)

## Injection Details

### Shellcode

The loader writes position-independent shellcode to Dock's address space that:
1. Calls `pthread_create_from_mach_thread` to spawn a proper pthread
2. The pthread calls `dlopen(payload_path, RTLD_LAZY)`
3. dlopen triggers `__attribute__((constructor))` in payload
4. Main thread spins with magic value `0x79616265` ("yabe") in x0/rax to signal completion

### PAC (Pointer Authentication)

On arm64e, function pointers must be PAC-signed. The loader:
1. Signs the thread PC with `ptrauth_sign_unauthenticated(code, ptrauth_key_asia, 0)`
2. Calls `thread_convert_thread_state` to convert for target thread
3. Uses terminate + `thread_create_running` pattern (required for macOS 14.4+)

## Requirements

- macOS 14.0+ (Sonoma)
- SIP with debugging restrictions disabled:
  ```bash
  csrutil enable --without debug  # From recovery mode
  ```
- Accessibility permissions for main binary

## Troubleshooting

### Socket not created

Check if payload loaded:
```bash
ls -la /tmp/yabai.zig-sa_*.socket
```

If missing, try:
```bash
sudo killall Dock
sleep 2
sudo ./zig-out/bin/yabai.zig --load-sa
```

### Injection fails

Check SIP status:
```bash
csrutil status
```

Must show "Debugging Restrictions: disabled"
