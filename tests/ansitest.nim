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
# The parser and the rows it draws on
# ---------------------------------------------------------------------------

proc rowsOf(input: string; tabSize = 2): seq[TermRow] =
  ## Everything a chunk produced: the rows it finished with and the ones still
  ## open to being drawn on.
  var sc = initTermScreen()
  result = sc.feed(input, tabSize)
  for r in sc.rows: result.add r

proc textOf(input: string; tabSize = 2): string =
  var parts: seq[string] = @[]
  for r in rowsOf(input, tabSize): parts.add r.text
  result = parts.join("\L")

proc colorsOf(input: string): string =
  ## Every row as `text:Class` runs, rows separated by ` / `.
  var lines: seq[string] = @[]
  for r in rowsOf(input):
    let text = r.text
    var pos = 0
    var parts: seq[string] = @[]
    for run in r.runs:
      parts.add text[pos ..< pos + run.len] & ":" & $run.tc
      pos += run.len
    lines.add parts.join(" ")
  result = lines.join(" / ")

echo "text comes out clean:"

block:
  equals("plain text is left alone", textOf("hello"), "hello")
  equals("a color is taken out", textOf("\e[32mgreen\e[m"), "green")
  equals("a cursor move nobody answers here is swallowed",
         textOf("a\e[24;1Hb"), "ab")
  equals("hide and show", textOf("a\e[?25lb\e[?25hc"), "abc")
  equals("a two-byte escape", textOf("a\e7b\eMc"), "abc")
  equals("an OSC ending in BEL", textOf("a\e]0;a title\ab"), "ab")
  equals("an OSC ending in ST", textOf("a\e]8;;http://x\e\\b"), "ab")
  equals("a lone ESC at the end is held back, not printed",
         textOf("ab\e"), "ab")
  equals("tabs become spaces", textOf("a\tb", tabSize = 4), "a    b")
  equals("a newline is a new row", textOf("a\nb"), "a\Lb")
  equals("and a pty's \\r\\n is the same thing said twice",
         textOf("a\c\Lb"), "a\Lb")
  equals("a rune of several bytes stays whole", textOf("a—b"), "a—b")

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
  check("a row that was colored says so", rowsOf("\e[32ma")[0].colored)
  check("and one that was not does not", not rowsOf("plain")[0].colored)

echo "what a progress meter does:"

block:
  # The whole point: a meter rewrites its line rather than adding one.
  equals("a carriage return draws over the line again",
         textOf("\r 10%\r 50%\r100%"), "100%")
  equals("erase to the end of the line rubs out what was longer",
         textOf("aaaaaaaaaa\r\e[Kshort"), "short")
  equals("erase the whole line", textOf("hello\e[2Kbye"), "     bye")
  equals("a backspace steps back over one column",
         textOf("abcx\bd"), "abcd")
  equals("an absolute column", textOf("..........\e[5Gx"), "....x.....")
  equals("forward and back", textOf("abc\e[2Dx"), "axc")

block:
  # A meter that counts several things at once draws them on several rows and
  # goes back up to the first.
  # The row after them is where the cursor was left standing, and it is empty.
  equals("two rows, drawn on again from the top",
         textOf("one\ntwo\n\e[2Aone!\ntwo!"), "one!\Ltwo!\L")
  # Up and down keep the column they are in -- only a carriage return or a
  # newline goes back to the left, which is what makes `\r` the meter's tool.
  equals("down is the other way, and stays in its column",
         textOf("a\n\e[1Ax\e[1Bb"), "x\L b")

block:
  # Rows the meter has printed past are final: they are handed over, and the
  # cursor can no longer reach them.
  var sc = initTermScreen()
  var final = sc.feed("keep\n", 2)
  check("a row still within reach is not final yet", final.len == 0,
        $final.len)
  var lines = ""
  for i in 1 .. LiveRows + 4: lines.add "row" & $i & "\n"
  final = sc.feed(lines, 2)
  check("but one pushed past the tail is", final.len == 6, $final.len)
  equals("and it is the oldest that goes first", final[0].text, "keep")
  check("the tail keeps its bound", sc.rows.len == LiveRows, $sc.rows.len)

echo "a chunk boundary anywhere:"

block:
  var sc = initTermScreen()
  discard sc.feed("red \e[3", 2)
  equals("the half-written escape is held back", sc.rows[0].text, "red ")
  discard sc.feed("2mgreen", 2)
  equals("and is finished by the chunk after it, in its color",
         sc.rows[0].text, "red green")
  check("which is the color it carried", sc.rows[0].colored)

block:
  var sc = initTermScreen()
  discard sc.feed("a\e]0;half a ti", 2)
  discard sc.feed("tle\ab", 2)
  equals("an OSC split down the middle", sc.rows[0].text, "ab")

block:
  var sc = initTermScreen()
  discard sc.feed("a\xE2\x80", 2)      # an em dash, cut after two bytes
  discard sc.feed("\x94b", 2)
  equals("a rune split down the middle", sc.rows[0].text, "a—b")

block:
  var sc = initTermScreen()
  discard sc.feed("\e[33m", 2)
  discard sc.feed("still yellow", 2)
  equals("a color outlives the chunk that asked for it",
         sc.rows[0].runs[0].tc.`$`, "Yellow")

block:
  # An `ESC` in the middle of a binary file starts a sequence that never ends,
  # and holding on to the rest of the file waiting for it is how a terminal
  # that met a `.tar` stops showing anything at all.
  var sc = initTermScreen()
  discard sc.feed("\e]" & repeat('x', 4000), 2)
  discard sc.feed("after", 2)
  equals("a runaway escape is given up on", sc.rows[0].text, "after")

echo "what git actually prints:"

block:
  # Copied off a `git log -p` read through a pty, `\r\n` and all.
  const diff = "\e[33mcommit abc123\e[m\c\L\e[1mdiff --git\e[m\c\L" &
               "\e[36m@@ -1 +1 @@\e[m\c\L\e[32m+added\e[m\c\L\e[31m-gone\e[m\c\L"
  equals("the diff reads as a diff", textOf(diff),
         "commit abc123\Ldiff --git\L@@ -1 +1 @@\L+added\L-gone\L")
  equals("in the colors it asked for", colorsOf(diff),
         "commit abc123:Yellow / diff --git:BrightWhite / " &
         "@@ -1 +1 @@:Cyan / +added:Green / -gone:Red / ")

# ---------------------------------------------------------------------------
# Into a buffer
# ---------------------------------------------------------------------------

echo "the colors survive in the buffer:"

const Area = rect(0, 0, 400, 300)

proc console(): SynEdit =
  result = createSynEdit(font, defaultTheme())
  result.lang = langConsole

proc show(ed: var SynEdit; r: TermRow) =
  ## What `Terminal.renderRow` does.
  let start = ed.len
  ed.appendOutput(r.text & "\L", highlight = not r.colored)
  if r.colored:
    var pos = start
    for run in r.runs:
      if run.tc != TokenClass.None: ed.setStyleRange(pos, pos + run.len - 1, run.tc)
      pos += run.len
    ed.markProgramColored(pos)

proc show(ed: var SynEdit; raw: string) =
  for r in rowsOf(raw, ed.tabSize): ed.show(r)

proc classAt(ed: SynEdit; needle: string; text: string): TokenClass =
  let i = text.find(needle)
  doAssert i >= 0, needle
  ed.tokenClassAt(i)

block:
  # A line that starts with `-` is what the highlighter paints red by guessing.
  # Here the program says it is green, and the program wins.
  var ed = console()
  ed.show("\e[32m-not really a deletion\e[m")
  check("the program's color is the one that lands",
        ed.tokenClassAt(0) == TokenClass.Green, $ed.tokenClassAt(0))

block:
  var ed = console()
  ed.show("\e[36mcyan\e[m")
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
  ed.show("+added\n-gone")
  ed.render(Area, showCursor = true)
  let text = ed.fullText
  check("a `+` line is still guessed green",
        ed.classAt("+added", text) == TokenClass.Green,
        $ed.classAt("+added", text))
  check("and a `-` line red", ed.classAt("-gone", text) == TokenClass.Red,
        $ed.classAt("-gone", text))

block:
  var ed = console()
  ed.show("\e[33myellow\e[m")
  ed.show("+added")
  ed.render(Area, showCursor = true)
  let text = ed.fullText
  check("the colored row keeps the program's color",
        ed.classAt("yellow", text) == TokenClass.Yellow,
        $ed.classAt("yellow", text))
  check("and the plain one after it is still guessed",
        ed.classAt("+added", text) == TokenClass.Green,
        $ed.classAt("+added", text))

echo "taking a row back off:"

block:
  # What redrawing the live tail rests on.
  var ed = console()
  ed.appendOutput("keep\Lgone\Lalso gone")
  let at = ed.fullText.find("gone")
  ed.truncateOutput(at)
  equals("everything from there is dropped", ed.fullText, "keep\L")
  var newlines = 0
  for i in 0 ..< ed.len:
    if ed[i] == '\L': inc newlines
  check("and the buffer holds one line break, not three", newlines == 1,
        $newlines)
  ed.appendOutput("new\L")
  equals("and the buffer goes on from there", ed.fullText, "keep\Lnew\L")

block:
  var ed = console()
  ed.show("\e[32mgreen\e[m")
  let mark = ed.len
  ed.show("\e[31mred\e[m")
  ed.truncateOutput(mark)
  ed.appendOutput("plain\L")
  ed.render(Area, showCursor = true)
  check("what was kept keeps its color",
        ed.tokenClassAt(0) == TokenClass.Green, $ed.tokenClassAt(0))
  let text = ed.fullText
  equals("and what was dropped is gone", text, "green\Lplain\L")

echo "landing at the top of what a command printed:"

block:
  # The panel is its own pager -- it scrolls, searches and keeps everything --
  # but a pager also decides where you *start*, and following the output down
  # leaves the reader at the oldest commit in the repository.
  var ed = console()
  var back = ""
  for i in 1..50: back.add "old " & $i & "\L"
  ed.appendOutput(back)
  ed.appendOutput("$ git log\L")
  ed.render(Area, showCursor = true)
  let start = ed.len                 # where the command's own output begins
  var printed = ""
  for i in 1..100: printed.add "commit " & $i & "\L"
  ed.appendOutput(printed)
  ed.appendOutput("$ ")
  ed.render(Area, showCursor = true)
  check("by default the view has followed the output down",
        ed.firstLine > 100, $ed.firstLine)
  ed.scrollToOutput(start)
  ed.render(Area, showCursor = true)
  check("and a pager lands on the first line of it",
        ed.firstLine == 51, $ed.firstLine)
  # The caret is still down at the prompt, off the bottom of the view: moving
  # it is what brings the view back, so the first key typed returns there.
  check("with the caret still at the prompt", ed.cursor == ed.len, $ed.cursor)
  # Typing does not chase the caret by itself, so the panel says so on the
  # reader's behalf -- `Terminal.caretToEnd` does this for every key that
  # edits the command line.
  ed.revealCaret()
  ed.insertText("x")
  ed.render(Area, showCursor = true)
  check("and the way back down is one keystroke", ed.firstLine > 100,
        $ed.firstLine)

block:
  var ed = console()
  ed.appendOutput("$ cd src\L")
  ed.render(Area, showCursor = true)
  let start = ed.len
  ed.appendOutput("two\Llines\L")
  ed.appendOutput("$ ")
  ed.render(Area, showCursor = true)
  let before = ed.firstLine
  ed.scrollToOutput(start)
  ed.render(Area, showCursor = true)
  check("output that already fits is left exactly where it was",
        ed.firstLine == before, $ed.firstLine & " was " & $before)

quit(if failures > 0: 1 else: 0)
