## The tab list is a list whose active row is chosen somewhere else. The editor
## decides which tab is current -- Ctrl+W, a file opened from the explorer, a
## jump to a definition -- and the list has to go and show it, which nothing in
## the list itself ever asked for. `centerLine` is that move, and this watches
## the two things that make it stick: that it does not fall off either end of
## the list, and that drawing the widget afterwards leaves it where it was,
## focused or not.
import uirelays/[screen, coords, input]
import widgets/[synedit, theme]

fontRelays = FontRelays(
  openFont: proc (path: string; size: int; style: FontStyles;
                  metrics: var FontMetrics): Font =
    metrics = FontMetrics(ascent: 12, descent: 4, lineHeight: 16)
    Font(1),
  closeFont: proc (f: Font) = discard,
  getFontMetrics: proc (f: Font): FontMetrics =
    FontMetrics(ascent: 12, descent: 4, lineHeight: 16),
  measureText: proc (f: Font; text: string): TextExtent =
    TextExtent(w: text.len * 8, h: 16),
  drawText: proc (f: Font; x, y: int; text: string;
                  fg, bg: Color): TextExtent =
    TextExtent(w: text.len * 8, h: 16))

drawRelays = DrawRelays(
  fillRect: proc (r: Rect; c: Color) = discard,
  drawLine: proc (x1, y1, x2, y2: int; color: Color) = discard,
  drawPoint: proc (x, y: int; color: Color) = discard,
  loadImage: proc (path: string): Image = Image(0),
  freeImage: proc (img: Image) = discard,
  drawImage: proc (img: Image; src, dst: Rect) = discard)

clipboardRelays = ClipboardRelays(
  getText: proc (): string = "",
  putText: proc (text: string) = discard)

var m: FontMetrics
let font = openFont("", 16, m)

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

const Area = rect(0, 0, 200, 200)   # twelve rows of sixteen pixels

proc newList(count: int): SynEdit =
  ## A tab list of `count` short names, drawn once so that it has a height.
  result = createSynEdit(font, defaultTheme())
  result.lang = langNone
  var text = ""
  for i in 0 ..< count:
    if i > 0: text.add "\n"
    text.add "tab" & $i
  result.setText(text)
  discard result.draw(default(Event), Area, focused = false)

proc frame(ed: var SynEdit; focused: bool) =
  discard ed.draw(default(Event), Area, focused)

echo "centring a row:"

block: # a list far longer than the panel
  var ed = newList(100)
  let rows = ed.span - 1
  check("the panel has a height to speak of", rows >= 8, $ed.span)
  ed.centerLine(50)
  check("a row in the middle of the list lands in the middle of the panel",
        ed.firstLine.int == 50 - rows div 2,
        $ed.firstLine & " of " & $ed.span)
  check("and stays there when the list is drawn unfocused",
        (ed.frame(focused = false); ed.firstLine.int == 50 - rows div 2),
        $ed.firstLine)

block: # the ends, where half a panel of blanks would be the naive answer
  var ed = newList(100)
  ed.centerLine(0)
  check("the first row cannot be centred, so the view stays at the top",
        ed.firstLine.int == 0, $ed.firstLine)
  ed.centerLine(99)
  let rows = ed.span - 1
  check("the last row comes to rest on the bottom row of the panel",
        ed.firstLine.int == 100 - rows, $ed.firstLine & " of " & $ed.span)
  check("which is to say the last row is visible",
        99 >= ed.firstLine.int and 99 < ed.firstLine.int + rows,
        $ed.firstLine)

block: # a list that fits
  var ed = newList(5)
  ed.centerLine(4)
  check("a list shorter than the panel does not scroll at all",
        ed.firstLine.int == 0, $ed.firstLine)

block: # never drawn, so it has no middle yet
  var ed = createSynEdit(font, defaultTheme())
  ed.setText("a\nb\nc")
  ed.centerLine(2)
  check("a panel that has not been drawn is left alone",
        ed.firstLine.int == 0, $ed.firstLine)

echo "and stepping on from it:"

block: # why the caret is moved along with the view, and not the view alone
  # The list's caret is what the arrow keys move and what Enter activates, so
  # a list scrolled to the active tab with its caret left behind reads right
  # and answers wrong: the first Down goes to the row after whatever the list
  # was last looking at, somewhere off the top of the panel.
  var ed = newList(100)
  ed.gotoLine(1, 0)           # the list was rebuilt; caret back at the top
  ed.gotoLine(51, 0)          # focim sends it after the active tab (row 50)
  ed.centerLine(50)
  let at = ed.firstLine.int
  check("the caret is on the row that was centred", ed.currentLine == 50,
        $ed.currentLine)
  ed.frame(focused = false)
  ed.frame(focused = true)    # the list gets the focus back
  check("taking the focus back leaves the view where it was put",
        ed.firstLine.int == at, $ed.firstLine & " was " & $at)
  discard ed.draw(Event(kind: KeyDownEvent, key: KeyDown), Area,
                  focused = true)
  check("and Down steps to the tab below the active one",
        ed.currentLine == 51, $ed.currentLine)

block: # and that the view really was moved, not merely left at the top
  var ed = newList(100)
  ed.gotoLine(1, 0)
  ed.frame(focused = false)
  check("the list starts at the top", ed.firstLine.int == 0, $ed.firstLine)
  ed.gotoLine(91, 0)
  ed.centerLine(90)
  ed.frame(focused = false)
  let rows = ed.span - 1
  check("and follows the active tab down to row 90",
        ed.firstLine.int == 90 - rows div 2, $ed.firstLine)

if failures == 0:
  echo "PASS"
else:
  echo "FAIL ", failures
  quit 1
