## paint.nim -- Simple drawing app using uirelays.
## Click and drag to paint. Right-click to clear. Scroll to change brush size.
##
## Compile:
##   nim c examples/paint.nim

import uirelays/[coords, screen, input, backend]

const MaxStrokes = 100_000

type
  Stroke = object
    x, y, size: int
    col: Color

proc main =
  initBackend()

  let layout = createWindow(800, 600)
  var width = layout.width
  var height = layout.height
  setWindowTitle("Paint - uirelays example")

  var strokes: seq[Stroke]
  var brushSize = 4
  var brushColor = color(137, 180, 250)
  var painting = false
  var running = true

  let palette = [
    color(137, 180, 250),  # blue
    color(245, 194, 231),  # pink
    color(166, 227, 161),  # green
    color(249, 226, 175),  # yellow
    color(243, 139, 168),  # red
    color(205, 214, 244),  # white
  ]

  while running:
    var e: Event
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowResizeEvent, WindowMetricsEvent:
        width = e.x; height = e.y
      of KeyDownEvent:
        if e.key == KeyEsc: running = false
        # Number keys 1-6 pick palette color
        if e.key >= Key1 and e.key <= Key6:
          brushColor = palette[e.key.ord - Key1.ord]
      of MouseDownEvent:
        if e.button == LeftButton:
          # Check if click is on a palette swatch
          var pickedPalette = false
          for i, c in palette:
            let sx = 10 + i * 30
            if rect(sx, 8, 22, 22).contains(point(e.x, e.y)):
              brushColor = c
              pickedPalette = true
              break
          if not pickedPalette:
            painting = true
            if strokes.len < MaxStrokes:
              strokes.add Stroke(x: e.x, y: e.y, size: brushSize, col: brushColor)
        elif e.button == RightButton:
          strokes.setLen(0)  # clear canvas
      of MouseUpEvent:
        if e.button == LeftButton:
          painting = false
      of MouseMoveEvent:
        if painting and strokes.len < MaxStrokes:
          strokes.add Stroke(x: e.x, y: e.y, size: brushSize, col: brushColor)
      of MouseWheelEvent:
        brushSize = clamp(brushSize + e.y, 1, 40)
      else: discard

    # --- draw ---
    let bg = color(30, 30, 46)
    fillRect(rect(0, 0, width, height), bg)

    # draw all strokes
    for s in strokes:
      fillRect(rect(s.x - s.size, s.y - s.size, s.size * 2, s.size * 2), s.col)

    # HUD: palette at top
    let fg = color(205, 214, 244)
    for i, c in palette:
      let x = 10 + i * 30
      fillRect(rect(x, 8, 22, 22), c)
      if c == brushColor:
        drawLine(x, 32, x + 22, 32, fg)

    # brush size indicator
    fillRect(rect(width - 50, 8, 22, 22), brushColor)

    refresh()
    sleep(16)

  shutdown()

main()
