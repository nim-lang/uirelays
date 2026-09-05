# uirelays

Native Nim UI library based on the idea of "relays" -- dependency injection
via global callbacks. Has Windows API, X11, Cocoa, GTK4, SDL2, SDL3 and FigDraw
support. Write UI apps as easily as terminal apps!

[![focim](screenshots/focim.png)](https://github.com/Araq/focim)

*[focim](https://github.com/Araq/focim), the Focussed Nim Editor, is
written with it.*

## Getting started

`import uirelays` is all you need -- it re-exports everything and
automatically initializes the native backend for the current platform
(WinAPI on Windows, Cocoa on macOS, X11 on Linux/BSD). Override with
`-d:sdl3`, `-d:sdl2`, `-d:gtk4`, or a FigDraw Nimble feature.

For finer control, import the submodules directly and call `initBackend()`
yourself:

```nim
import uirelays/[coords, screen, input, backend]
initBackend()
```

## Installation

Install this package with Nimble:

```sh
nimble install
```

Backend selection:

- Default on Windows: WinAPI
- Default on macOS: Cocoa
- Default on Linux/BSD: X11
- Optional overrides: `-d:gtk4`, `-d:sdl3`, `-d:sdl2`
- Optional features: `figDrawWindy` and `figDrawSiwin`

### FigDraw backend

Choose either the Windy or siwin integration. The features are mutually
exclusive and install only the selected windowing dependency:

```sh
atlas install --feature:uirelays.figDrawWindy
nim c --define:"features.uirelays.figDrawWindy" examples/hello.nim

atlas install --feature:uirelays.figDrawSiwin
nim c --define:"features.uirelays.figDrawSiwin" examples/hello.nim
```

The matching `-d:figDrawWindy` and `-d:figDrawSiwin` convenience aliases are
also accepted once their dependencies are available.

### Nim Packages For SDL Backends

The SDL backends need extra Nim packages in addition to the native system
libraries:

```sh
nimble install https://github.com/nim-lang/sdl3
nimble install https://github.com/nim-lang/sdl2
```

Install `sdl3` when building with `-d:sdl3`. Install `sdl2` when building
with `-d:sdl2`.

### Linux

Choose the backend you want and install its native development packages.

#### Ubuntu

Default X11 backend:

```sh
sudo apt install libx11-dev libxft-dev
```

GTK4 backend:

```sh
sudo apt install libgtk-4-dev libpango1.0-dev libcairo2-dev libfontconfig1-dev libglib2.0-dev pkg-config
```

SDL3 backend:

```sh
sudo apt install libsdl3-dev libsdl3-ttf-dev
nimble install https://github.com/nim-lang/sdl3
```

SDL2 backend:

```sh
sudo apt install libsdl2-dev libsdl2-ttf-dev
nimble install https://github.com/nim-lang/sdl2
```

#### Fedora

Default X11 backend:

```sh
sudo dnf install libX11-devel libXft-devel
```

GTK4 backend:

```sh
sudo dnf install gtk4-devel pango-devel cairo-devel fontconfig-devel glib2-devel pkgconf-pkg-config
```

SDL3 backend:

```sh
sudo dnf install SDL3-devel SDL3_ttf-devel
nimble install https://github.com/nim-lang/sdl3
```

SDL2 backend:

```sh
sudo dnf install SDL2-devel SDL2_ttf-devel
nimble install https://github.com/nim-lang/sdl2
```

### macOS

The default Cocoa backend needs no extra native libraries.

```sh
nim c examples/hello.nim
```

For SDL backends on macOS, install the SDL libraries with your preferred
package manager, then install the matching Nim package:

```sh
nimble install https://github.com/nim-lang/sdl3
nimble install https://github.com/nim-lang/sdl2
```

### Windows

The default WinAPI backend needs no extra native libraries.

```sh
nim c examples/hello.nim
```

For SDL backends on Windows, install the SDL native libraries separately
and then install the matching Nim package:

```sh
nimble install https://github.com/nim-lang/sdl3
nimble install https://github.com/nim-lang/sdl2
```

### Build Examples

Use the default backend for your platform:

```sh
nim c examples/hello.nim
```

Force a specific backend:

```sh
nim c -d:gtk4 examples/hello.nim
nim c -d:sdl3 examples/hello.nim
nim c -d:sdl2 examples/hello.nim
nim c --define:"features.uirelays.figDrawWindy" examples/hello.nim
nim c --define:"features.uirelays.figDrawSiwin" examples/hello.nim
```

## Apps

- [focim](https://github.com/Araq/focim) -- the Focussed Nim Editor: a code
  editor with an integrated terminal, laid out and colored by an editable
  config file. It lived in this repository until it outgrew it; the widgets it
  is made of -- SynEdit, the terminal panel, the clipboard history -- went with
  it, since they were an editor's parts and not a UI library's.

## Examples

- [hello.nim](examples/hello.nim) -- Minimal window with text rendering
- [paint.nim](examples/paint.nim) -- Simple drawing app with explicit submodule imports
- [layout_demo.nim](examples/layout_demo.nim) -- NIF layout system demo
- [todo.nim](examples/todo.nim) -- Todo list app

## Architecture

The library is split into five relay groups:

| Module | Relays | Purpose |
|--------|--------|---------|
| `screen` | `windowRelays` | Window lifecycle, cursor, clip rect |
| `screen` | `fontRelays` | Font loading, text measurement and rendering |
| `screen` | `drawRelays` | Rectangles, lines, points, images |
| `input` | `inputRelays` | Events, timing, shutdown |
| `input` | `clipboardRelays` | Copy/paste |

Drivers populate these relay objects at init time. Application code calls
convenience wrappers (`fillRect`, `drawText`, `waitEvent`, ...) that
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
| `figdraw_windy_driver` | Cross-platform | FigDraw, Windy |
| `figdraw_siwin_driver` | Cross-platform | FigDraw, siwin |

See [Writing a custom driver](doc/drivers.md) for a guide on
adding support for a new platform or graphics toolkit.

## Layout

A window's boxes are described in NIF -- a
parenthesized format read by the dependency-free lexer in `uirelays/tinynif`
-- and `uirelays/layout` turns that description into a `Rect` per name:

```
(layout
  (toolbar (lines 2))
  (cols
    (sidebar (px 250))
    (editor))
  (status (lines 1)))
```

`(rows ...)` stacks its children top to bottom, `(cols ...)` places them left
to right, and either may hold the other. Every other tag is a leaf that names
a widget and may state its size along the axis its parent divides: `(px 250)`
in logical pixels, `(lines 5)` in text lines, `(stretch 2)` in shares of what
is left over. `resolve` computes the rects; `hitTest` says which name a click
landed in. See [layout_demo.nim](examples/layout_demo.nim).

The borders are draggable, and nothing has to be drawn for them to be: the
`gap` `resolve` leaves between adjacent boxes is already there, so it is the
grip. `splitterAt` says which border a pointer is on, `dragTo` moves it, and
`$` writes the layout back out as the text it came from -- with the new sizes
in the unit each box was already written in, a `(px N)` staying pixels and a
`(lines N)` snapping to whole lines. An application that keeps its layout in a
file therefore gets mouse-resizable panels without keeping a second copy of
the sizes anywhere: what the pointer moves is what the file says.

## License

MIT
