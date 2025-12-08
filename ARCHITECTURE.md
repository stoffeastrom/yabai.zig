# Architecture

yabai.zig is a tiling window manager for macOS. This document describes the codebase structure and key patterns.

## Directory Structure

```
src/
├── main.zig           # Entry point, CLI parsing, service management
├── Daemon.zig         # Main daemon - event loop, state coordination
├── config/            # Configuration parsing and hot-reload
├── core/              # Domain types (Window, Space, View, Layout)
├── events/            # Event types and event loop
├── ipc/               # IPC server, command/query handlers
├── platform/          # macOS platform APIs (SkyLight, Accessibility)
├── sa/                # Scripting Addition (Dock injection)
├── state/             # State management (WindowTable, Spaces, Apps)
└── trace/             # Performance tracing
```

## Core Concepts

### State Management

All mutable state lives in the `Daemon` struct, organized into domain-specific managers:

- **WindowTable** (`state/WindowTable.zig`): Single source of truth for window tracking. Stores window ID → Entry mapping with indexes by space and PID. All window mutations go through here.

- **Windows** (`state/Windows.zig`): Wrapper around WindowTable with configuration (FFM mode, opacity settings).

- **Spaces** (`state/Spaces.zig`): Space labels, Views (layout state per space), current/last space tracking.

- **Apps** (`state/Apps.zig`): Application tracking by PID.

### Dirty Flags Pattern

Instead of reacting immediately to events, the daemon accumulates "dirty" flags:

```zig
dirty: DirtyFlags = .{},  // layout_current, layout_all, refresh_windows, etc.
```

Once per run loop tick, `processDirtyState()` handles all accumulated changes. This:
- Batches multiple events into single operations
- Prevents redundant work
- Makes event handling predictable

### Event Flow

```
macOS Events (workspace observer, accessibility)
    ↓
Event.zig (tagged union of all event types)
    ↓
EventLoop.zig (thread-safe queue)
    ↓
Daemon.processEvent() → sets dirty flags
    ↓
Daemon.processDirtyState() → applies changes
```

### Views and Layout

Each space has a `View` (`core/View.zig`) that tracks:
- Layout type (bsp, stack, float)
- Window order for that space
- Padding and gap configuration

`View.calculateFrames()` computes window positions. `Spaces.applyLayout()` applies them using cached `ax_ref` from WindowTable.

### Cross-Space Operations

AX (Accessibility) APIs only work for windows on the current space. For cross-space operations:

1. **Window discovery**: Use SkyLight (`SLSCopyWindowsWithOptionsAndTags`)
2. **Frame operations**: Use cached `ax_ref` from WindowTable (stored when window was on current space)
3. **Space operations**: Use Scripting Addition (injected into Dock)

### Scripting Addition (SA)

Some operations require injection into Dock.app:
- Create/destroy spaces
- Move windows between spaces
- Focus spaces directly

See `SA.md` for details on the injection mechanism.

Architecture:
```
yabai.zig ←─unix socket─→ payload.m (in Dock) → SkyLight
```

The SA client (`sa/client.zig`) sends messages to the injected payload.

## Key Files

| File | Purpose |
|------|---------|
| `Daemon.zig` | Main coordinator - events, state, IPC |
| `state/WindowTable.zig` | Central window registry |
| `state/Spaces.zig` | Space management and layout application |
| `core/View.zig` | Per-space layout state and frame calculation |
| `core/Window.zig` | Window operations (get/set frame, focus) |
| `platform/skylight.zig` | SkyLight private API bindings |
| `platform/accessibility.zig` | AX API wrappers |
| `ipc/CommandHandler.zig` | IPC command processing |
| `config/Config.zig` | Config file parsing |

## Adding Features

### New IPC Command

1. Add command parsing in `ipc/CommandHandler.zig`
2. Implement handler, typically calling methods on `Daemon`
3. If state changes needed, set appropriate dirty flags

### New Event Type

1. Add variant to `events/Event.zig`
2. Add case in `Daemon.processEvent()`
3. Set dirty flags or handle immediately

### New Window State

1. Add field to `WindowTable.Entry`
2. Add setter method in `WindowTable` (maintains indexes)
3. Expose through `Windows` wrapper if needed

## Patterns to Follow

- **Single source of truth**: Window state in WindowTable, space state in Spaces
- **Dirty flags**: Don't react immediately, set flags and batch process
- **Cached ax_ref**: Use for frame operations, works cross-space
- **SkyLight for queries**: Works cross-space, use for window discovery
- **SA for space mutations**: Create/destroy/focus spaces via injected payload

## Testing

```bash
zig build test                    # Run all tests
zig build test -- --test-filter   # Run specific tests

# Manual testing
tail -f /tmp/yabai.zig.log
./zig-out/bin/yabai.zig -m query --windows
```
