## uirelays - Native Nim UI library based on dependency injection via
## global callbacks ("relays"). Has Windows API, X11, Cocoa, GTK4,
## SDL2 and SDL3 support.
##
## Importing this module re-exports coords, screen and input, and
## automatically selects and initializes the native backend for the
## current platform. For finer control, import the submodules directly
## and call ``initBackend()`` yourself.

import uirelays / [coords, screen, input, backend]
export coords, screen, input

initBackend()
