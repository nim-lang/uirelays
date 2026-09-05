## What a program printed, once the escape sequences have been taken out of
## it: the text a buffer should hold, the colors the program asked for, and --
## just as much the point -- that everything it asked for which this panel has
## no answer to disappears instead of coming out as `^[[?25h` in the middle of
## a line. Needs no window for the parser half; the half that puts the colors
## into a SynEdit runs through the same stub relays as `styletest`.
import std/strutils
import uirelays/[screen, coords, input]
import widgets/[ansi, synedit, theme]

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

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

# ---------------------------------------------------------------------------
# The parser
# ---------------------------------------------------------------------------

proc textOf(input: string; tabSize = 2): string =
  var st = initAnsiState()
  var runs: seq[AnsiRun] = @[]
  discard st.parseAnsi(input, tabSize, result, runs)

proc colorsOf(input: string): string =
  ## The runs as `text:Class`, so a test can name both at once.
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  discard st.parseAnsi(input, 2, text, runs)
  var pos = 0
  var parts: seq[string] = @[]
  for r in runs:
    parts.add text[pos ..< pos + r.len] & ":" & $r.tc
    pos += r.len
  result = parts.join(" ")

proc sawColor(input: string): bool =
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  result = st.parseAnsi(input, 2, text, runs)

echo "text comes out clean:"

block:
  equals("plain text is left alone", textOf("hello"), "hello")
  equals("a color is taken out", textOf("\e[32mgreen\e[m"), "green")
  equals("and so is a cursor move", textOf("a\e[24;1Hb"), "ab")
  equals("erase, hide, show", textOf("a\e[Kb\e[?25lc\e[?25hd"), "abcd")
  equals("a two-byte escape", textOf("a\e7b\eMc"), "abc")
  equals("an OSC ending in BEL", textOf("a\e]0;a title\ab"), "ab")
  equals("an OSC ending in ST", textOf("a\e]8;;http://x\e\\b"), "ab")
  equals("a lone ESC at the end is held back, not printed",
         textOf("ab\e"), "ab")
  # `rawInsert` expands tabs and drops carriage returns, so the parser has to
  # do it too -- a run counts bytes the buffer will actually hold.
  equals("tabs are expanded the way the buffer expands them",
         textOf("a\tb", tabSize = 4), "a    b")
  equals("carriage returns are dropped", textOf("a\c\Lb"), "a\Lb")

echo "colors are the ones asked for:"

block:
  equals("the eight", colorsOf("\e[31mr\e[32mg\e[33my\e[34mb\e[m."),
         "r:Red g:Green y:Yellow b:Blue .:None")
  equals("reset by 0 as well as by nothing",
         colorsOf("\e[36mc\e[0m."), "c:Cyan .:None")
  equals("39 is the default too", colorsOf("\e[35mm\e[39m."),
         "m:Magenta .:None")
  # `ls --color=always` says `01;34` and every terminal since the VT100 has
  # drawn that as bright blue.
  equals("bold makes a color its bright twin",
         colorsOf("\e[01;34mdir\e[0m"), "dir:BrightBlue")
  equals("and 22 takes it off again",
         colorsOf("\e[1;31ma\e[22mb"), "a:BrightRed b:Red")
  equals("the bright eight say so themselves",
         colorsOf("\e[90ma\e[97mb"), "a:BrightBlack b:BrightWhite")
  # `git log` marks its `commit` and `diff --git` lines with nothing but this.
  equals("bold alone is the default color, emphasised",
         colorsOf("\e[1mbold\e[m"), "bold:BrightWhite")

block:
  # Claude Code's own output, which is where the 24-bit ones come from.
  equals("24-bit gray lands on the nearest of the sixteen",
         colorsOf("\e[38;2;153;153;153ma\e[m"), "a:BrightBlack")
  equals("24-bit amber lands on yellow",
         colorsOf("\e[38;2;255;193;7ma\e[m"), "a:Yellow")
  equals("256-color red", colorsOf("\e[38;5;196ma\e[m"), "a:BrightRed")
  equals("256-color index below 16 is that color",
         colorsOf("\e[38;5;2ma\e[m"), "a:Green")
  equals("a background is swallowed, and takes its arguments with it",
         colorsOf("\e[48;2;0;0;0mx\e[49my"), "xy:None")
  equals("so is one of 256", colorsOf("\e[48;5;17mx\e[m"), "x:None")

block:
  equals("a private sequence is not a color", colorsOf("\e[>4mx"), "x:None")
  equals("nor is a keyboard query", colorsOf("\e[<ux"), "x:None")
  check("SGR is what sets the flag", sawColor("\e[32ma"))
  check("a cursor move does not", not sawColor("a\e[2Jb\e[Hc"))
  check("and neither does plain text", not sawColor("hello"))

echo "a chunk boundary anywhere:"

block:
  # A `read` returns what has arrived, which may be four bytes into a color.
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  discard st.parseAnsi("red \e[3", 2, text, runs)
  equals("the half-written escape is held back", text, "red ")
  discard st.parseAnsi("2mgreen", 2, text, runs)
  equals("and finished by the chunk after it", text, "red green")
  var pos = 0
  var last = TokenClass.None
  for r in runs:
    if pos + r.len == text.len: last = r.tc
    pos += r.len
  check("the color it carried is in force", last == TokenClass.Green, $last)

block:
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  discard st.parseAnsi("a\e]0;half a ti", 2, text, runs)
  discard st.parseAnsi("tle\ab", 2, text, runs)
  equals("an OSC split down the middle", text, "ab")

block:
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  discard st.parseAnsi("\e[33m", 2, text, runs)
  discard st.parseAnsi("still yellow", 2, text, runs)
  equals("a color outlives the chunk that asked for it",
         colorsOf("\e[33mstill yellow"), "still yellow:Yellow")
  check("across chunks as well", runs.len == 1 and runs[0].tc == TokenClass.Yellow,
        $runs.len)

block:
  # An `ESC` in the middle of a binary file starts a sequence that never ends,
  # and holding on to the rest of the file waiting for it is how a terminal
  # that met a `.tar` stops showing anything at all.
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  discard st.parseAnsi("\e]" & repeat('x', 4000), 2, text, runs)
  discard st.parseAnsi("after", 2, text, runs)
  equals("a runaway escape is given up on", text, "after")

echo "what git actually prints:"

block:
  # Copied off `git -c color.ui=always log -p`.
  const diff = "\e[33mcommit abc123\e[m\L\e[1mdiff --git\e[m\L" &
               "\e[36m@@ -1 +1 @@\e[m\L\e[32m+added\e[m\L\e[31m-gone\e[m\L"
  equals("the diff reads as a diff", textOf(diff),
         "commit abc123\Ldiff --git\L@@ -1 +1 @@\L+added\L-gone\L")
  equals("in the colors it asked for", colorsOf(diff),
         "commit abc123:Yellow \L:None diff --git:BrightWhite \L:None " &
         "@@ -1 +1 @@:Cyan \L:None +added:Green \L:None -gone:Red \L:None")

# ---------------------------------------------------------------------------
# Into a buffer
# ---------------------------------------------------------------------------

echo "the colors survive in the buffer:"

const Area = rect(0, 0, 400, 300)

proc console(): SynEdit =
  result = createSynEdit(font, defaultTheme())
  result.lang = langConsole

proc show(ed: var SynEdit; raw: string) =
  ## What `Terminal.showOutput` does, in the two lines of it that matter here.
  var st = initAnsiState()
  var text = ""
  var runs: seq[AnsiRun] = @[]
  let colored = st.parseAnsi(raw, ed.tabSize, text, runs)
  let start = ed.len
  ed.appendOutput(text, highlight = not colored)
  if colored:
    var pos = start
    for r in runs:
      if r.tc != TokenClass.None: ed.setStyleRange(pos, pos + r.len - 1, r.tc)
      pos += r.len
    ed.markProgramColored(pos)

proc classAt(ed: SynEdit; needle: string; text: string): TokenClass =
  let i = text.find(needle)
  doAssert i >= 0, needle
  ed.tokenClassAt(i)

block:
  # A line that starts with `-` is what the highlighter paints red by guessing.
  # Here the program says it is green, and the program wins.
  var ed = console()
  ed.show("\e[32m-not really a deletion\e[m\L")
  check("the program's color is the one that lands",
        ed.tokenClassAt(0) == TokenClass.Green, $ed.tokenClassAt(0))

block:
  var ed = console()
  ed.show("\e[36mcyan\e[m\L")
  # An edit sends the incremental highlighter back to the start of the buffer,
  # and a render is where it runs. Without the watermark it would repaint the
  # program's output with whatever the shape of the lines suggests.
  ed.insertText("typing")
  ed.render(Area, showCursor = true)
  ed.render(Area, showCursor = true)
  check("and it survives an edit further down",
        ed.tokenClassAt(0) == TokenClass.Cyan, $ed.tokenClassAt(0))

block:
  # Output with no escapes in it is still the highlighter's to color, or a
  # plain `git diff` would come out grey.
  var ed = console()
  ed.show("+added\L-gone\L")
  ed.render(Area, showCursor = true)
  let text = ed.fullText
  check("a `+` line is still guessed green",
        ed.classAt("+added", text) == TokenClass.Green,
        $ed.classAt("+added", text))
  check("and a `-` line red", ed.classAt("-gone", text) == TokenClass.Red,
        $ed.classAt("-gone", text))

block:
  # The two kinds of chunk, one after the other.
  var ed = console()
  ed.show("\e[33myellow\e[m\L")
  ed.show("+added\L")
  ed.render(Area, showCursor = true)
  let text = ed.fullText
  check("the colored chunk keeps the program's color",
        ed.classAt("yellow", text) == TokenClass.Yellow,
        $ed.classAt("yellow", text))
  check("and the plain one after it is still guessed",
        ed.classAt("+added", text) == TokenClass.Green,
        $ed.classAt("+added", text))

quit(if failures > 0: 1 else: 0)
