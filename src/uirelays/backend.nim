## Automatic platform driver selection.
## Uses the native backend for each OS, with `-d:` overrides for
## cross-platform toolkits.
##
## Override flags (checked first):
##   -d:sdl3    Force SDL3 backend
##   -d:sdl2    Force SDL2 backend
##   -d:gtk4    Force GTK4 backend

when defined(sdl3):
  import drivers/sdl3_driver
  proc initBackend*() = initSdl3Driver()

elif defined(sdl2):
  import drivers/sdl2_driver
  proc initBackend*() = initSdl2Driver()

elif defined(gtk4):
  import drivers/gtk4_driver
  proc initBackend*() = initGtk4Driver()

elif defined(macosx):
  import drivers/cocoa_driver
  proc initBackend*() = initCocoaDriver()

elif defined(windows):
  import drivers/winapi_driver
  proc initBackend*() = initWinapiDriver()

elif defined(linux) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  import drivers/x11_driver
  proc initBackend*() = initX11Driver()

else:
  import drivers/sdl3_driver
  proc initBackend*() = initSdl3Driver()
