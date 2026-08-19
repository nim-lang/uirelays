## The band under the caret must be under the *caret*. It is painted per line
## number, while the caret is drawn from a position in the buffer, and the two
## are held together by `firstLine` and the offset the line at the top of the
## view begins at -- a number and a position that an edit anywhere above the
## view pulls apart. This watches them through stub relays: the band is a
## `fillRect` in a color used for nothing else, so where it went is something
## the test can simply read off.
import std/random
import uirelays/[screen, coords, input]
import widgets/[synedit, theme]

const BandColor = color(1, 2, 3)

var bands: seq[Rect]

proc recordFill(r: Rect; c: Color) =
  if c == BandColor: bands.add r

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
  fillRect: recordFill,
  drawLine: proc (x1, y1, x2, y2: int; color: Color) = discard,
  drawPoint: proc (x, y: int; color: Color) = discard,
  loadImage: proc (path: string): Image = Image(0),
  freeImage: proc (img: Image) = discard,
  drawImage: proc (img: Image; src, dst: Rect) = discard)

clipboardRelays = ClipboardRelays(
  getText: proc (): string = "pasted",
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

proc newEd(): SynEdit =
  var th = defaultTheme()
  th.activeLineBg = BandColor
  result = createSynEdit(font, th)

proc realLine(ed: SynEdit): int =
  ## The line the caret is on, counted the slow and obvious way.
  result = 0
  for i in 0 ..< ed.cursor:
    if ed[i] == '\L': inc result

proc caretIsBanded(ed: SynEdit): bool =
  ## Is the row the caret was drawn on one of the rows the band covers?
  let cur = ed.cursorRect
  if cur.h <= 0: return false
  for b in bands:
    if b.y <= cur.y and cur.y < b.y + b.h: return true

proc key(k: KeyCode; mods: set[Modifier] = {}): Event =
  Event(kind: KeyDownEvent, key: k, mods: mods)

proc typed(c: char): Event =
  result = Event(kind: TextInputEvent)
  result.text[0] = c

const
  Area = rect(0, 0, 300, 200)      # twelve rows of sixteen pixels
  Text = "alpha beta\ngamma\n\n    delta epsilon\nzeta\n" &
         "eta theta iota kappa lambda mu nu xi omicron pi\nrho\nsigma\n" &
         "tau\nupsilon\nphi\nchi\npsi\nomega\n"

proc frame(ed: var SynEdit; e = default(Event)) =
  bands.setLen 0
  discard ed.draw(e, Area, focused = true)

echo "the caret's line:"

block: # the view is scrolled off the caret, and then the caret's line is edited
  var ed = newEd()
  ed.setText(Text)
  ed.gotoPos(0)
  ed.frame()
  # Ctrl+Down scrolls without moving the caret, so the caret ends up above the
  # view -- and the character typed next moves every line start below it.
  for i in 1..3: ed.frame(key(KeyDown, {CtrlPressed}))
  ed.frame(typed('x'))
  check("typing above the view brings the view back to the caret",
        ed.cursorRect.h > 0, $ed.cursorRect)
  check("and the band is on the caret's row", ed.caretIsBanded(),
        $ed.cursorRect & " " & $bands)
  check("and the caret's line is still the caret's line",
        ed.currentLine == ed.realLine,
        $ed.currentLine & " vs " & $ed.realLine)

block: # the same with a deletion, which moves line starts the other way
  var ed = newEd()
  ed.setText(Text)
  ed.gotoPos(0)
  ed.frame()
  for i in 1..3: ed.frame(key(KeyDown, {CtrlPressed}))
  ed.frame(key(KeyDelete))
  check("deleting above the view leaves the band on the caret's row",
        ed.caretIsBanded(), $ed.cursorRect & " " & $bands)

block: # a line that wraps is one line, and all of its rows are banded
  var ed = newEd()
  ed.setText(Text)
  ed.gotoLine(6, 0)             # the long one
  ed.frame(key(KeyEnd))
  check("the band reaches the caret on a wrapped line", ed.caretIsBanded(),
        $ed.cursorRect & " " & $bands)

block: # and then the same question asked several thousand times
  let keys = [KeyLeft, KeyRight, KeyUp, KeyDown, KeyHome, KeyEnd,
              KeyPageUp, KeyPageDown, KeyBackspace, KeyDelete, KeyEnter,
              KeyTab, KeyZ, KeyY, KeyV, KeyA]
  let mods = [{}, {ShiftPressed}, {CtrlPressed}, {CtrlPressed, ShiftPressed}]
  let mouse = [MouseDownEvent, MouseUpEvent, MouseMoveEvent, MouseWheelEvent]
  var r = initRand(20260819)
  var lineFails = 0
  var bandFails = 0
  for round in 1..400:
    var ed = newEd()
    ed.setText(Text)
    ed.gotoPos(r.rand(ed.len))
    for step in 1..40:
      var e: Event
      case r.rand(5)
      of 0:
        let k = r.sample(mouse)
        e = Event(kind: k, x: r.rand(Area.w), y: r.rand(Area.h),
                  clicks: 1 + r.rand(2))
        if k == MouseWheelEvent:
          e.x = 0
          e.y = r.rand(6) - 3
      of 1:
        e = typed(r.sample(["a", "b", " ", "\t"])[0])
      else:
        e = key(r.sample(keys), r.sample(mods))
      ed.frame(e)
      if ed.currentLine != ed.realLine: inc lineFails
      if ed.cursorRect.h > 0 and bands.len > 0 and not ed.caretIsBanded():
        inc bandFails
  check("the caret's line survives 16000 random operations", lineFails == 0,
        $lineFails & " of them said otherwise")
  check("and the band never lands on another row", bandFails == 0,
        $bandFails & " of them said otherwise")

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
