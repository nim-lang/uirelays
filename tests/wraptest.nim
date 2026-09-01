## A line too long for the widget: does all of it get drawn, and can the caret
## still be found once it has been wrapped? Both are answered by watching the
## drawing path through stub relays, the way `styletest` does -- no window and
## no driver, and a font whose every glyph is 8 pixels wide, so what lands
## where is arithmetic rather than a screenshot.
import std/[strutils, sequtils]
import uirelays/[screen, coords, input]
import widgets/[synedit, theme]

const
  GlyphW = 8
  Ellipsis = "\xE2\x80\xA6"

var drawn: seq[tuple[x, y: int, text: string]]

fontRelays = FontRelays(
  openFont: proc (path: string; size: int; style: FontStyles;
                  metrics: var FontMetrics): Font =
    metrics = FontMetrics(ascent: 12, descent: 4, lineHeight: 16)
    Font(1),
  closeFont: proc (f: Font) = discard,
  getFontMetrics: proc (f: Font): FontMetrics =
    FontMetrics(ascent: 12, descent: 4, lineHeight: 16),
  measureText: proc (f: Font; text: string): TextExtent =
    TextExtent(w: text.len * GlyphW, h: 16),
  drawText: proc (f: Font; x, y: int; text: string;
                  fg, bg: Color): TextExtent =
    if text.len > 0: drawn.add (x, y, text)
    TextExtent(w: text.len * GlyphW, h: 16))

drawRelays = DrawRelays(
  fillRect: proc (r: Rect; color: Color) = discard,
  drawLine: proc (x1, y1, x2, y2: int; color: Color) = discard,
  drawPoint: proc (x, y: int; color: Color) = discard,
  loadImage: proc (path: string): Image = Image(0),
  freeImage: proc (img: Image) = discard,
  drawImage: proc (img: Image; src, dst: Rect) = discard)

var m: FontMetrics
let font = openFont("", 16, m)

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc text(): string =
  ## Everything that was drawn, in the order it was drawn, without the marks
  ## that only say a break happened.
  for d in drawn:
    if d.text != Ellipsis: result.add d.text

proc rows(): int =
  ## How many rows were drawn on.
  var seen: seq[int] = @[]
  for d in drawn:
    if d.y notin seen: seen.add d.y
  result = seen.len

proc newConsole(): SynEdit =
  result = createSynEdit(font, defaultTheme())
  result.lang = langConsole

proc newMarkdown(): SynEdit =
  result = createSynEdit(font, defaultTheme())
  result.lang = langMarkdown

proc rowStarts(): seq[int] =
  ## Where each row begins: the leftmost thing drawn on it, which for a row a
  ## line was wrapped onto is the mark that sits at the continuation indent.
  var ys: seq[int] = @[]
  for d in drawn:
    let k = ys.find(d.y)
    if k < 0:
      ys.add d.y
      result.add d.x
    else:
      result[k] = min(result[k], d.x)

const
  Cmd = "nim c --define:release --out:bin/foo src/foo.nim && echo done"
  Prompt = "/home/araq> "
  Area = rect(0, 0, 300, 200)   # 300 px is a little over 36 characters

var e = default(Event)

echo "wrapping:"

block: # the whole of a long line is drawn, not just the part that fits
  var ed = newConsole()
  ed.setText(Prompt & Cmd)
  ed.gotoPos(ed.len)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  check("a long line is drawn to its last character", text() == Prompt & Cmd,
        "'" & text() & "'")
  check("and onto rows of its own", rows() == 3, $rows())
  check("every break is marked at both ends",
        drawn.countIt(it.text == Ellipsis) == (rows() - 1) * 2,
        $drawn.countIt(it.text == Ellipsis))
  # The mark at the end of a row goes where the space that was kept free for
  # it is, and this font makes a three-byte glyph three characters wide, so
  # only the text itself is held to the edge.
  check("no text is drawn past the right edge",
        drawn.allIt(it.text == Ellipsis or
                    it.x + it.text.len * GlyphW <= Area.w))

block: # a line that fits is left alone
  var ed = newConsole()
  ed.setText("ls -l")
  ed.gotoPos(ed.len)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  check("a short line stays on one row", rows() == 1, $rows())
  check("and gets no marks", not drawn.anyIt(it.text == Ellipsis))

block: # the caret is on the wrapped part, and the prompt is at the bottom
  var ed = newConsole()
  discard ed.draw(e, Area, focused = true)   # a first frame, so `span` is known
  for i in 1..20:
    ed.appendOutput("line " & $i & "\L")
    discard ed.draw(e, Area, focused = true)
  ed.appendOutput(Prompt)
  for c in Cmd: ed.insertText($c)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  check("typing past the edge of the last line keeps the caret in view",
        ed.cursorRect.h > 0 and ed.cursorRect.y + ed.cursorRect.h <= Area.h,
        $ed.cursorRect)
  check("and the end of what was typed is on screen",
        text().endsWith(Cmd), "'" & text() & "'")
  # Following the caret is for a caret that moved. The wheel says the opposite
  # -- look somewhere else -- and has to be able to leave it behind.
  let before = ed.firstLine
  ed.wheelScroll(3)
  check("the wheel scrolls away from the caret", ed.firstLine < before,
        $ed.firstLine)
  discard ed.draw(e, Area, focused = true)
  check("and the view stays where the wheel put it", ed.firstLine < before,
        $ed.firstLine)

block: # text that is not ASCII must not be cut in the middle of a rune
  var ed = newConsole()
  # No letter/non-letter edge anywhere in it, so every break is a forced one.
  ed.setText("\xC3\xA4".repeat(40))
  ed.gotoPos(ed.len)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  check("a forced break falls between runes, not inside one",
        drawn.allIt(it.text == Ellipsis or it.text.len mod 2 == 0),
        drawn.mapIt($it.text.len).join(","))
  check("and all of it is still drawn", text().len == 80, $text().len)

block: # a widget too narrow for even one character must still terminate
  var ed = newConsole()
  ed.setText(Cmd)
  ed.gotoPos(ed.len)
  drawn.setLen 0
  discard ed.draw(e, rect(0, 0, 12, 100), focused = true)
  check("a widget narrower than a glyph draws what it can and stops", true)

echo ""
echo "wrapping prose:"

const Prose = "This is prose that goes on, and on, and on, and on, " &
              "and on and on and on and on."

block: # a comma in a sentence is not a bracket: it opens nothing to line up on
  var ed = newMarkdown()
  ed.setText(Prose)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  let starts = rowStarts()
  check("a wrapped sentence needs more than one row", starts.len > 1,
        $starts.len)
  check("and its continuation starts where the sentence did",
        starts.allIt(it == starts[0]), starts.mapIt($it).join(","))

block: # what a line is indented by, its continuation is indented by too
  var ed = newMarkdown()
  ed.setText("    " & Prose)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  let starts = rowStarts()
  check("an indented paragraph continues at its own indentation",
        starts.len > 1 and starts[1..^1].allIt(it == starts[0] + 4 * GlyphW),
        starts.mapIt($it).join(","))

block: # a list item hangs under its own text, not under its bullet
  var ed = newMarkdown()
  ed.setText("- " & Prose)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  let starts = rowStarts()
  check("a bullet gives its item a hanging indent",
        starts.len > 1 and starts[1..^1].allIt(it == starts[0] + 2 * GlyphW),
        starts.mapIt($it).join(","))

block: # a numbered item hangs by however wide its number is
  var ed = newMarkdown()
  ed.setText("10. " & Prose)
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  let starts = rowStarts()
  check("a number gives its item a hanging indent",
        starts.len > 1 and starts[1..^1].allIt(it == starts[0] + 4 * GlyphW),
        starts.mapIt($it).join(","))

block: # code is code, wherever it is: a bracket still opens something
  var ed = createSynEdit(font, defaultTheme())
  ed.lang = langNim
  ed.setText("let x = foo(someArgument, anotherArgument, aThirdArgument, 12)")
  drawn.setLen 0
  discard ed.draw(e, Area, focused = true)
  let starts = rowStarts()
  check("a call still lines its arguments up behind the bracket",
        starts.len > 1 and starts[1..^1].allIt(it > starts[0]),
        starts.mapIt($it).join(","))

echo ""
echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
