# Writing a custom driver

A driver is a Nim module that populates the five global relay objects
from `screen` and `input` with platform-specific implementations.
It exports a single `initMyDriver*()` proc.

This guide walks through creating a driver from scratch.

## Structure

A minimal driver looks like this:

```
mydriver.nim
  import uirelays/[coords, screen, input]

  # ... implementation procs ...

  proc initMyDriver*() =
    windowRelays = WindowRelays(...)
    fontRelays   = FontRelays(...)
    drawRelays   = DrawRelays(...)
    inputRelays  = InputRelays(...)
    clipboardRelays = ClipboardRelays(...)
```

Every relay field must be assigned. Fields left at their defaults are
no-op stubs that return zero values, so a partially implemented driver
will compile and run -- it just won't do anything for the missing parts.

## The five relay groups

### WindowRelays

| Field | Signature | Notes |
|-------|-----------|-------|
| `createWindow` | `proc (layout: var ScreenLayout)` | Create and show the window. Read `layout.width/height` for the requested size, write back the actual size. |
| `refresh` | `proc ()` | Present the current frame. For double-buffered drivers this means copying the back buffer to the window. |
| `saveState` | `proc ()` | Push the current graphics state (clip rect). |
| `restoreState` | `proc ()` | Pop the graphics state. |
| `setClipRect` | `proc (r: Rect)` | Restrict drawing to the given rectangle. |
| `setCursor` | `proc (c: CursorKind)` | Change the mouse cursor shape. |
| `setWindowTitle` | `proc (title: string)` | Set the window title bar text. |

### FontRelays

| Field | Signature | Notes |
|-------|-----------|-------|
| `openFont` | `proc (path: string; size: int; metrics: var FontMetrics): Font` | Load a font from a TTF file path at the given pixel size. Write metrics (ascent, descent, lineHeight). Return an opaque handle (1-based int; 0 = failure). |
| `closeFont` | `proc (f: Font)` | Free a font handle. |
| `getFontMetrics` | `proc (f: Font): FontMetrics` | Return cached metrics for an open font. |
| `measureText` | `proc (f: Font; text: string): TextExtent` | Measure the pixel dimensions of a UTF-8 string without drawing it. |
| `drawText` | `proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent` | Draw text at (x, y) with foreground and background colors. y is the top of the text, not the baseline. Return the extent. |

Font handles are `distinct int`, 1-based. Drivers typically maintain a
`seq[FontSlot]` and return `Font(slots.len)` after appending.

### DrawRelays

| Field | Signature | Notes |
|-------|-----------|-------|
| `fillRect` | `proc (r: Rect; color: Color)` | Fill a rectangle with a solid color. |
| `drawLine` | `proc (x1, y1, x2, y2: int; color: Color)` | Draw a line between two points. |
| `drawPoint` | `proc (x, y: int; color: Color)` | Set a single pixel. |
| `loadImage` | `proc (path: string): Image` | Load an image from file. Return opaque handle (1-based; 0 = failure). |
| `freeImage` | `proc (img: Image)` | Free an image handle. |
| `drawImage` | `proc (img: Image; src, dst: Rect)` | Draw a region of an image into a destination rectangle. |

### InputRelays

| Field | Signature | Notes |
|-------|-----------|-------|
| `pollEvent` | `proc (e: var Event; flags: set[InputFlag]): bool` | Non-blocking. Drain the platform message queue, return the next event. Return false if no events are pending. |
| `waitEvent` | `proc (e: var Event; timeoutMs: int; flags: set[InputFlag]): bool` | Block until an event arrives or the timeout expires (timeoutMs < 0 = wait forever). Must keep pumping the platform message queue while waiting to avoid "not responding" states. |
| `getTicks` | `proc (): int` | Monotonic millisecond counter. |
| `sleep` | `proc (ms: int)` | Sleep for the given number of milliseconds. Should pump the platform message queue during the sleep if possible. |
| `shutdown` | `proc ()` | Tear down the window and release platform resources. |

The `flags` parameter carries `InputFlag` values. Currently the only
flag is `WantTextInput`, which tells the driver to show the on-screen
keyboard or enable IME. Desktop drivers can ignore it.

### ClipboardRelays

| Field | Signature | Notes |
|-------|-----------|-------|
| `getText` | `proc (): string` | Read UTF-8 text from the system clipboard. |
| `putText` | `proc (text: string)` | Write UTF-8 text to the system clipboard. |

## Double buffering

Most drivers use a double-buffered approach:

1. All drawing procs (`fillRect`, `drawText`, ...) render into an
   off-screen buffer (pixmap, bitmap, texture).
2. `refresh()` copies the back buffer to the visible window surface.
3. On resize, recreate the back buffer at the new dimensions.

This eliminates flicker and simplifies the rendering model.

## Event translation

The driver's event loop reads platform-native events and translates them
into `Event` values. Key points:

- **KeyDown/KeyUp**: Translate platform keycodes or scancodes to `KeyCode`
  enum values. Set `e.mods` from the current modifier state.
- **TextInput**: Produce a separate `TextInputEvent` with the UTF-8
  codepoint in `e.text[0..3]`. This is distinct from KeyDown -- a single
  key press may produce both a KeyDown and a TextInput event.
- **Mouse**: Set `e.x`, `e.y` to client-area coordinates. For MouseDown,
  set `e.button` and `e.clicks` (track double/triple clicks yourself).
- **Scroll**: `MouseWheelEvent` with `e.y` as the scroll direction
  (+1 up, -1 down).
- **Window**: Emit `WindowResizeEvent` with the new size in `e.x`, `e.y`.
  Emit `WindowCloseEvent` when the user clicks the close button (don't
  destroy the window -- let the app decide). Emit `QuitEvent` for
  platform quit signals.

## Font path to face name

The `openFont` relay receives a file path (e.g.
`C:\Windows\Fonts\consola.ttf`). Depending on your platform you may
need to convert this to a face name for the native font API:

- **GDI (Windows)**: Use `AddFontResourceExW` to install the file,
  then `CreateFontW` with the face name. Map known filenames to face
  names, or use `GetFontResourceInfoW`.
- **Xft (X11)**: Use a fontconfig pattern string like
  `"DejaVu Sans Mono:pixelsize=15"`. Fontconfig resolves installed
  fonts by name.
- **SDL_ttf**: Takes file paths directly -- no conversion needed.

## Registering with the backend module

To make your driver selectable via the automatic backend, add a branch
to `uirelays/backend.nim`:

```nim
elif defined(myplatform):
  import drivers/my_driver
  proc initBackend*() = initMyDriver()
```

Or users can bypass the backend module entirely and call
`initMyDriver()` directly after importing your driver.

## Checklist

- [ ] Implement all 5 relay groups (or leave unneeded ones at defaults)
- [ ] Double-buffer all drawing, present on `refresh()`
- [ ] Translate platform events to `Event` values
- [ ] Handle window close without destroying the window
- [ ] Pump the message queue in `sleep()` and `waitEvent()` to stay responsive
- [ ] Track double/triple clicks in MouseDown
- [ ] Convert font file paths to platform face names
- [ ] Test: window appears, text renders, mouse clicks register, keyboard input works, clipboard works, resize works
