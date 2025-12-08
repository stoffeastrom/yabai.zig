# yabai.zig

A Zig port of [yabai](https://github.com/koekeishiya/yabai) - a tiling window manager for macOS.

This is a hobby project to learn Zig while reimplementing yabai. It is **not** intended as a replacement - use the original for production.

## Status

Work in progress. Core features work:
- BSP tiling layout
- Space management (create, destroy, focus, move windows)
- Focus-follows-mouse
- Window rules
- Config hot-reloading

## Key Differences from yabai

**Runtime SA extraction**: Instead of shipping pre-compiled Scripting Addition bundles, yabai.zig discovers SkyLight private API addresses at runtime by pattern-matching the Dock binary. No SA updates needed for new macOS versions (unless patterns change).

**Declarative config**: Uses a simple key=value config format instead of shell scripts.

## Requirements

- macOS 14.0+ (Sonoma)
- Zig 0.14.0+
- SIP debugging disabled: `csrutil enable --without debug` (from recovery mode)

## Quick Start

```bash
# Build
zig build

# Install service
./zig-out/bin/yabai.zig --install-service

# Load scripting addition (requires sudo)
sudo ./zig-out/bin/yabai.zig --load-sa

# Start service
./zig-out/bin/yabai.zig --start-service
```

## Commands

```bash
# Service management
--install-service    Install launchd service
--uninstall-service  Remove launchd service
--start-service      Start the service
--stop-service       Stop the service
--restart-service    Restart the service

# Scripting Addition
--load-sa            Inject SA into Dock (requires sudo)
--unload-sa          Remove SA from Dock (requires sudo)
--reload-sa          Kill Dock and re-inject SA
--install-sudoers    Allow passwordless sudo for --load-sa

# Other
--check-sa           Verify SA pattern matching works
-m <domain> <cmd>    Send message to running instance
```

## Configuration

Config file: `~/.config/yabai.zig/config`

```bash
# Layout
layout = bsp
window_gap = 8
top_padding = 8
bottom_padding = 8
left_padding = 8
right_padding = 8

# Behavior
focus_follows_mouse = autofocus
auto_balance = on

# Rules (app:title patterns)
rule = Finder:* manage=off
rule = System Settings:* manage=off
```

## IPC

```bash
# Space commands
./zig-out/bin/yabai.zig -m space --create
./zig-out/bin/yabai.zig -m space --create --take  # Create and move focused window
./zig-out/bin/yabai.zig -m space --destroy
./zig-out/bin/yabai.zig -m space --focus next

# Window commands
./zig-out/bin/yabai.zig -m window --focus next
./zig-out/bin/yabai.zig -m window --swap next
./zig-out/bin/yabai.zig -m window --space 3

# Query
./zig-out/bin/yabai.zig -m query --windows
./zig-out/bin/yabai.zig -m query --spaces
```

## Development

```bash
zig build              # Build
zig build test         # Run tests
zig build dev          # Build and run with dev script

# After changes
zig build && ./zig-out/bin/yabai.zig --restart-service

# Logs
tail -f /tmp/yabai.zig.log
```

## Credits

Based on [yabai](https://github.com/koekeishiya/yabai) by [@koekeishiya](https://github.com/koekeishiya).

Also inspired by [skhd.zig](https://github.com/jackielii/skhd.zig).

## License

MIT
