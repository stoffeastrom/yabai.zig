# yabai.zig

A hobby project porting [yabai](https://github.com/koekeishiya/yabai) to Zig.

This is a fun experiment to learn Zig while reimplementing a tiling window manager for macOS. It is **not** intended as a replacement for yabai - if you want a production-ready tiling window manager, use the original.

## Status

Work in progress. Many features are missing or incomplete.

## Key Differences from yabai

**Runtime SA extraction**: Instead of shipping pre-compiled Scripting Addition bundles for each macOS version, yabai.zig attempts to discover SkyLight private API addresses at runtime by pattern-matching against the running Dock process. This means:
- No need to update SA bundles for each macOS release
- May break on major macOS changes (patterns need updating)
- Experimental approach - less battle-tested than yabai's method

**Zig port**: The initial conversion was bootstrapped using `zig translate-c` to convert the C codebase, then iteratively rewritten to idiomatic Zig with the help of Claude.

## Credits

This project is heavily inspired by and based on [yabai](https://github.com/koekeishiya/yabai) by [@koekeishiya](https://github.com/koekeishiya). The original yabai is an excellent tiling window manager for macOS, and this port would not exist without that work.

Also inspired by [skhd.zig](https://github.com/jackielii/skhd.zig) - a Zig port of skhd.

Key techniques and approaches borrowed from yabai:
- Scripting Addition (SA) injection for space management
- SkyLight private framework usage
- Window management via Accessibility APIs
- BSP layout algorithm

## Building

Requires Zig 0.15.2+ and macOS.

```bash
zig build
```

## Running

```bash
# Install certificate (first time only)
zig build run -- --install-cert

# Sign the binary (required for accessibility permissions)
zig build sign

# Run
zig build run-signed

# Or install as service
zig build run -- --install-service
zig build run -- --start-service
```

## Development

```bash
# Build and run (stops yabai, runs yabai.zig, restarts yabai on exit)
zig build dev

# Run tests
zig build test

# Analyze SA patterns in Dock (or any binary)
zig build run -- --check-sa
zig build run -- --check-sa /path/to/binary
```

## License

MIT - see original yabai for its licensing terms.
