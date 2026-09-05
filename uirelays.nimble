# Package

version       = "0.10.0"
author        = "Araq"
description   = "Native Nim UI library based on the idea of \"relays\" which is a new fancy name for dependency injections via global callbacks. Has Windows API, X11, Cocoa and SDL 3 support. Write UI apps as easily as terminal apps!"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.0"

feature "figdrawwindy":
  requires "figdraw >= 0.28.1"
  requires "windy >= 0.5.0"

feature "figdrawsiwin":
  requires "figdraw >= 0.28.1"
  requires "siwin >= 1.0.0"
