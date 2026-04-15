## Label -- simple read-only text widget for uirelays.
##
## Usage::
##
##   var title = createLabel(font, "Hello World")
##   # in your main loop:
##   title.draw(cells["title"])
##   # update text:
##   title.text = "New Title"

import ../uirelays/[coords, screen]

type
  Label* = object
    font: Font
    text*: string
    fg*: Color
    bg*: Color

proc createLabel*(font: Font; text = "";
                  fg = color(205, 214, 244);
                  bg = color(30, 30, 46)): Label =
  Label(font: font, text: text, fg: fg, bg: bg)

proc draw*(lab: Label; area: Rect) =
  fillRect(area, lab.bg)
  if lab.text.len > 0:
    let lineH = fontLineSkip(lab.font)
    let y = area.y + max(0, (area.h - lineH) div 2)
    discard drawText(lab.font, area.x + 4, y, lab.text, lab.fg, lab.bg)
