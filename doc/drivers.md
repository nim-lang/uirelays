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
| `createWindow` | `proc (layout: var ScreenLayout)` | Create and show the window. Read `layout.width/height` for the requested size, write back the actual size plus `scaleX/scaleY` and `uiScale` (see [Display density](#display-density)). |
| `getWindowLayout` | `proc (): ScreenLayout` | Return the current size and scale. Apps call this to re-read the density after the window may have moved to another monitor. |
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
- **Window**: Emit `WindowMetricsEvent` with the new size in `e.x`, `e.y` and
  the current scale in `e.scaleX`, `e.scaleY`, `e.uiScale`. Emit it whenever
  either the size *or* the density changes, so an app that only listens for
  this one event stays correct on both. `WindowResizeEvent` is the older,
  size-only event; it is still in the enum for drivers that have not been
  updated, but no driver in this repo emits it any more.
  Emit `WindowCloseEvent` when the user clicks the close button (don't
  destroy the window -- let the app decide). Emit `QuitEvent` for
  platform quit signals.

## Display density

A driver reports what it knows about the display with two integers -- never a
float, because a whole number of pixels per coordinate unit and a percentage
both are integers, and 125% or 150% stay exact:

| Field | Meaning |
|-------|---------|
| `scaleX`, `scaleY` | Device pixels the driver *already* puts per coordinate unit, so `width * scaleX` is the physical width. Informational: an app must not scale its own drawing by this. |
| `uiScale` | Percent an app should enlarge fonts and hardcoded pixel sizes by. 100 means the driver or the platform already accounts for the display's density. |

The distinction is the whole point, because the same scale factor means opposite
things on different platforms. Cocoa hands you *points* and renders into a 2x
backing store, so a 16pt font is already physically right: `scaleX = 2`,
`uiScale = 100`. X11 hands you raw *pixels* and scales nothing, so that same 16
is half the size it should be on a 192 dpi panel: `scaleX = 1`, `uiScale = 200`.
An app that multiplies its font sizes by `uiScale` -- via
`layout.scaled(size)` -- is correct on both, and gets crisp glyphs either way,
since the font is rasterized at its true size rather than a smaller raster
being blitted up.

What each driver in this repo reports:

| Driver | Coordinate unit | Density source | Reports |
|--------|-----------------|----------------|---------|
| `x11_driver` | device pixels | `Xft.dpi` resource | `scaleX = 1`, `uiScale = dpi * 100 / 96` |
| `winapi_driver` | device pixels | `GetDpiForWindow` | `scaleX = 1`, `uiScale = dpi * 100 / 96` |
| `cocoa_driver` | points | `backingScaleFactor` | `scaleX = 1` or `2`, `uiScale = 100` |
| `gtk4_driver` | logical pixels | `gtk_widget_get_scale_factor` | `scaleX = scale factor`, `uiScale = 100` |
| `sdl3_driver` | device pixels | pixel size / logical size | `scaleX = 1`, `uiScale` = that ratio |
| `sdl2_driver` | device pixels | none | `scaleX = 1`, `uiScale = 100` |
| `figdraw_*_driver` | logical pixels | `contentScale` | `scaleX` = rounded scale, `uiScale = 100` |

The size an app passes to `createWindow` is in the driver's coordinate unit too,
and a driver writes back what it actually got -- which may differ. On a 200%
display, `sdl3_driver` turns a requested 1100 into a 2200 pixel window (SDL
takes the request in logical units), while `x11_driver` gives you the 1100
device pixels you asked for. So always read `layout.width/height` back instead
of assuming the request was honoured.

Two things worth knowing when writing a new driver:

- **Do not report the physical density in `uiScale` if you already scale the
  drawing yourself.** Doing both makes text twice as large as asked.
- **The X server's advertised physical size is not a density source.** Xwayland
  reports a flat 96 dpi no matter the monitor, which is why `x11_driver` reads
  the `Xft.dpi` resource that the desktop environment writes instead.

`sdl2_driver` is the one driver that cannot find out: `SDL_GetDisplayDPI`
derives its answer from that same unreliable physical size, and SDL2 on Windows
is not DPI aware at all. Use the SDL3 driver on a HiDPI display.

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

Optional Nimble backends should be gated by their generated feature define,
for example `defined(feature.uirelays.figDrawWindy)`. This keeps their dependencies
out of default platform builds.

## Checklist

- [ ] Implement all 5 relay groups (or leave unneeded ones at defaults)
- [ ] Double-buffer all drawing, present on `refresh()`
- [ ] Translate platform events to `Event` values
- [ ] Handle window close without destroying the window
- [ ] Pump the message queue in `sleep()` and `waitEvent()` to stay responsive
- [ ] Track double/triple clicks in MouseDown
- [ ] Convert font file paths to platform face names
- [ ] Test: window appears, text renders, mouse clicks register, keyboard input works, clipboard works, resize works
