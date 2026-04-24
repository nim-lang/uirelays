## layout_demo.nim -- Demonstrates the layout manager.
## Parses a markdown table into named screen regions, draws them,
## highlights the region under the mouse, and resizes dynamically.
##
## Compile:
##   nim c examples/layout_demo.nim

import uirelays
import uirelays/layout
import std/tables

const LayoutSpec = """
  | toolbar, 30px                               |
  | sidebar, 200px | divider, 4px | editor, *   |
  | status, 1 line                              |
"""

const
  bg       = color(30, 30, 46)
  panelBg  = color(49, 50, 68)
  hoverBg  = color(69, 71, 90)
  divColor = color(88, 91, 112)
  fg       = color(205, 214, 244)
  accent   = color(137, 180, 250)

proc main =
  let win = createWindow(900, 600)
  var width = win.width
  var height = win.height

  var fm: FontMetrics
  let font = openFont("", 16, fm)
  setWindowTitle("Layout Demo")

  let parsed = parseLayout(LayoutSpec)

  var running = true
  var mouseX, mouseY = 0
  var hovered = ""

  while running:
    var e = default Event
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowResizeEvent, WindowMetricsEvent:
        width = e.x
        height = e.y
      of MouseMoveEvent:
        mouseX = e.x
        mouseY = e.y
      of KeyDownEvent:
        if e.key == KeyEsc or (e.key == KeyQ and CtrlPressed in e.mods):
          running = false
      else: discard

    let cells = parsed.resolve(width, height, fm.lineHeight)

    # hit test
    let hit = cells.hitTest(mouseX, mouseY)
    hovered = hit.name

    # background
    fillRect(rect(0, 0, width, height), bg)

    # draw each cell
    for name, r in cells:
      let isHover = name == hovered
      let cellBg = if name == "divider": divColor
                   elif isHover: hoverBg
                   else: panelBg
      fillRect(r, cellBg)

      # label
      let label = if isHover:
                    name & " (" & $r.w & "x" & $r.h & ")"
                  else:
                    name
      let labelFg = if isHover: accent else: fg
      discard drawText(font, r.x + 8, r.y + 6, label, labelFg, cellBg)

    # outline separators between cells
    for name, r in cells:
      drawLine(r.x, r.y, r.x + r.w, r.y, divColor)

    refresh()
    sleep(16)

  closeFont(font)
  shutdown()

main()
