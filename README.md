# yabai.zig

A Zig port of [yabai](https://github.com/koekeishiya/yabai) - tiling window manager for macOS.

**Status: Work in progress** - learning project, not for production use.

## Requirements

- macOS 14+ (Sonoma)
- Zig 0.14+
- SIP debugging disabled: `csrutil enable --without debug`

## Build & Run

```bash
zig build
sudo ./zig-out/bin/yabai.zig --load-sa
./zig-out/bin/yabai.zig
```

## Config

`~/.config/yabai.zig/config`:

```
layout = bsp
window_gap = 8
focus_follows_mouse = autofocus

rule = Finder:* manage=off
rule = System Settings:* manage=off
```

## Credits

Based on [yabai](https://github.com/koekeishiya/yabai) by [@koekeishiya](https://github.com/koekeishiya).

## License

MIT
