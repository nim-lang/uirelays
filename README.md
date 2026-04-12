# uirelays

Native Nim UI library based on the idea of "relays" -- dependency injection
via global callbacks. Has Windows API, X11, Cocoa, GTK4, SDL2 and SDL3
support. Write UI apps as easily as terminal apps!

## Getting started

`import uirelays` is all you need -- it re-exports everything and
automatically initializes the native backend for the current platform
(WinAPI on Windows, Cocoa on macOS, X11 on Linux/BSD). Override with
`-d:sdl3`, `-d:sdl2`, or `-d:gtk4`.

For finer control, import the submodules directly and call `initBackend()`
yourself:

```nim
import uirelays/[coords, screen, input, backend]
initBackend()
```

## Examples

- [hello.nim](examples/hello.nim) -- Uses `import uirelays` for maximum convenience
- [paint.nim](examples/paint.nim) -- Uses explicit submodule imports with manual `initBackend()`

## Architecture

The library is split into five relay groups:

| Module | Relays | Purpose |
|--------|--------|---------|
| `screen` | `windowRelays` | Window lifecycle, cursor, clip rect |
| `screen` | `fontRelays` | Font loading, text measurement and rendering |
| `screen` | `drawRelays` | Rectangles, lines, points, images |
| `input` | `inputRelays` | Events, timing, quit |
| `input` | `clipboardRelays` | Copy/paste |

Drivers populate these relay objects at init time. Application code calls
convenience wrappers (`fillRect`, `drawText`, `pollEvent`, ...) that
dispatch through the relays. No virtual calls, no inheritance, no heap
allocation -- just plain proc pointers.

## Drivers

| Driver | Platform | Dependencies |
|--------|----------|-------------|
| `winapi_driver` | Windows | None (GDI) |
| `cocoa_driver` | macOS | None (AppKit) |
| `x11_driver` | Linux/BSD | libX11, libXft |
| `gtk4_driver` | Linux/BSD | GTK4, Cairo, Pango |
| `sdl3_driver` | Cross-platform | SDL3, SDL3_ttf |
| `sdl2_driver` | Cross-platform | SDL2, SDL2_ttf |

See [Writing a custom driver](doc/writing_a_driver.md) for a guide on
adding support for a new platform or graphics toolkit.

## License

MIT
