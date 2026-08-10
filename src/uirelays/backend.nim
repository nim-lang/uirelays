## Automatic platform driver selection.
## Uses the native backend for each OS, with `-d:` overrides for
## cross-platform toolkits.
##
## Override flags (checked first):
##   --define:"feature.uirelays.figDrawWindy" Force FigDraw + Windy backend
##   --define:"feature.uirelays.figDrawSiwin" Force FigDraw + siwin backend
##   -d:sdl3    Force SDL3 backend
##   -d:sdl2    Force SDL2 backend
##   -d:gtk4    Force GTK4 backend

when (defined(feature.uirelays.figDrawWindy) or defined(figDrawWindy)) and
    (defined(feature.uirelays.figDrawSiwin) or defined(figDrawSiwin)):
  {.error: "figDrawWindy and figDrawSiwin are mutually exclusive".}

elif defined(feature.uirelays.figDrawWindy) or defined(figDrawWindy):
  import drivers/figdraw_windy_driver
  proc initBackend*() = initFigDrawWindyDriver()

elif defined(feature.uirelays.figDrawSiwin) or defined(figDrawSiwin):
  import drivers/figdraw_siwin_driver
  proc initBackend*() = initFigDrawSiwinDriver()

elif defined(sdl3):
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
