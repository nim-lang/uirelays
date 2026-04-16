## hello.nim -- Minimal uirelays example.
## Opens a window, draws some text and shapes, handles input.
##
## Compile:
##   nim c examples/hello.nim
##
## The native backend is selected automatically.
## Override with: -d:sdl3, -d:sdl2, -d:gtk4

import uirelays

proc main =
  let layout = createWindow(640, 480)
  var width = layout.width
  var height = layout.height

  var fm: FontMetrics
  let font = openFont("", 18, fm)  # empty path = platform default font
  setWindowTitle("Hello uirelays")

  var running = true
  var mouseX, mouseY = 0
  var clickMsg = "Click anywhere"

  while running:
    # --- process events ---
    var e: Event
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowResizeEvent:
        width = e.x
        height = e.y
      of MouseDownEvent:
        mouseX = e.x
        mouseY = e.y
        clickMsg = "Clicked at " & $e.x & ", " & $e.y
        if e.button == RightButton:
          clickMsg &= " (right)"
      of KeyDownEvent:
        if e.key == KeyEsc:
          running = false
        elif e.key == KeyQ and CtrlPressed in e.mods:
          running = false
      else: discard

    # --- draw frame ---
    let bg = color(30, 30, 46)
    let fg = color(205, 214, 244)
    let accent = color(137, 180, 250)
    let pink = color(245, 194, 231)
    let green = color(166, 227, 161)

    # background
    fillRect(rect(0, 0, width, height), bg)

    # title bar
    fillRect(rect(0, 0, width, 40), color(49, 50, 68))
    discard drawText(font, 12, 10, "Hello, uirelays!", fg, color(49, 50, 68))

    # colored boxes
    fillRect(rect(40, 60, 120, 80), accent)
    fillRect(rect(180, 60, 120, 80), pink)
    fillRect(rect(320, 60, 120, 80), green)

    # labels
    discard drawText(font, 60, 90, "Accent", bg, accent)
    discard drawText(font, 205, 90, "Pink", bg, pink)
    discard drawText(font, 345, 90, "Green", bg, green)

    # diagonal lines
    for i in 0 ..< 8:
      let x = 40 + i * 20
      drawLine(x, 170, x + 100, 270, accent)

    # click feedback
    discard drawText(font, 40, 300, clickMsg, fg, bg)

    # instructions
    discard drawText(font, 40, height - 40,
      "Press ESC or Ctrl+Q to quit", color(128, 128, 148), bg)

    refresh()
    sleep(16)  # ~60fps

  closeFont(font)
  shutdown()

main()
