## A rune is one character to the person editing it and several bytes to the
## buffer holding it, and every key that steps over one has to agree on where
## it ends. Delete used to ask for the length of the rune that *ends* at the
## caret when it wanted the one that *begins* there -- the same number for a
## dash of two bytes, one short for a dash of three -- so an em dash left a
## byte of itself behind, and the next Delete took the character in front of
## the caret along with it. Nothing here draws, so no window is needed.
import std/strutils
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

var m: FontMetrics
let font = openFont("", 16, m)

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc esc(s: string): string =
  ## What a byte that is not a letter is, so a failure names the byte and not
  ## whatever the terminal makes of half a rune.
  for c in s:
    if ord(c) < 32 or ord(c) > 126: result.add "\\x" & toHex(ord(c), 2)
    else: result.add c

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & esc(got) & "' want '" & esc(want) & "'")

const Area = rect(0, 0, 300, 200)

proc key(k: KeyCode; mods: set[Modifier] = {}): Event =
  Event(kind: KeyDownEvent, key: k, mods: mods)

proc buffer(text: string; pos: int): SynEdit =
  result = createSynEdit(font, defaultTheme())
  result.lang = langNone
  result.setText(text)
  result.gotoPos(pos)

proc press(ed: var SynEdit; k: KeyCode; mods: set[Modifier] = {}) =
  discard ed.draw(key(k, mods), Area, focused = true)

proc afterKeys(text: string; pos: int; k: KeyCode; times = 1): string =
  var ed = buffer(text, pos)
  for i in 1..times: ed.press(k)
  result = ed.fullText

# The dashes are the ones a word processor puts in: en dash and em dash, three
# bytes each. `é` is two, the emoji four, and `中` three again.
const
  EnDash = "–"
  EmDash = "—"
  Emoji = "\u{1F600}"

# ---------------------------------------------------------------------------
echo "Delete over a rune:"
# ---------------------------------------------------------------------------

block:
  equals("a dash of three bytes goes in one press",
         afterKeys("one " & EmDash & " two", 4, KeyDelete), "one  two")
  equals("and takes nothing with it on the press after",
         afterKeys("one " & EmDash & " two", 4, KeyDelete, 2), "one two")
  equals("an en dash the same", afterKeys("a" & EnDash & "b", 1, KeyDelete),
         "ab")
  equals("two bytes", afterKeys("caféx", 3, KeyDelete), "cafx")
  equals("three", afterKeys("a中b", 1, KeyDelete), "ab")
  equals("four", afterKeys("a" & Emoji & "b", 1, KeyDelete), "ab")
  equals("one", afterKeys("abc", 1, KeyDelete), "ac")
  equals("a newline is still a single byte",
         afterKeys("a\nb", 1, KeyDelete), "ab")
  equals("Delete at the end of the buffer does nothing",
         afterKeys("a" & EmDash, 4, KeyDelete), "a" & EmDash)

# ---------------------------------------------------------------------------
echo "Backspace over a rune:"
# ---------------------------------------------------------------------------

block:
  equals("a dash of three bytes goes in one press",
         afterKeys("one " & EmDash & " two", 7, KeyBackspace), "one  two")
  equals("two bytes", afterKeys("caféx", 5, KeyBackspace), "cafx")
  equals("four", afterKeys("a" & Emoji & "b", 5, KeyBackspace), "ab")
  equals("Backspace at the start of the buffer does nothing",
         afterKeys(EmDash & "a", 0, KeyBackspace), EmDash & "a")

# ---------------------------------------------------------------------------
echo "the caret steps over a whole rune:"
# ---------------------------------------------------------------------------

block:
  var ed = buffer("a" & EmDash & "b", 0)
  ed.press(KeyRight)
  check("Right lands in front of the rune", ed.cursor == 1, $ed.cursor)
  ed.press(KeyRight)
  check("and then past all of it", ed.cursor == 4, $ed.cursor)
  ed.press(KeyLeft)
  check("Left comes back to where it began", ed.cursor == 1, $ed.cursor)

block:
  # Right then Backspace and Left then Delete must land on the same character,
  # or one of the two is stepping over a different number of bytes.
  var a = buffer("x" & Emoji & "y", 1)
  a.press(KeyRight); a.press(KeyBackspace)
  var b = buffer("x" & Emoji & "y", 5)
  b.press(KeyLeft); b.press(KeyDelete)
  equals("the two directions agree", a.fullText, b.fullText)
  equals("and both took the rune", a.fullText, "xy")

# ---------------------------------------------------------------------------
echo "undo puts the rune back:"
# ---------------------------------------------------------------------------

block:
  var ed = buffer("one " & EnDash & " two", 4)
  ed.press(KeyDelete)
  ed.press(KeyZ, {CtrlPressed})
  equals("all of it, not the byte that a half-deletion left",
         ed.fullText, "one " & EnDash & " two")

# ---------------------------------------------------------------------------
echo "a file that is not UTF-8:"
# ---------------------------------------------------------------------------

block:
  # cp1252 writes an em dash as 0x97, which has the bit pattern of a
  # continuation byte and belongs to no rune. It has to stand for itself:
  # counting it as part of what came before would delete the neighbour.
  equals("a stray byte is deleted alone",
         afterKeys("one \x97 two", 4, KeyDelete), "one  two")
  equals("and backspaced alone",
         afterKeys("one \x97 two", 5, KeyBackspace), "one  two")
  equals("a run of them goes one at a time",
         afterKeys("a\x80\x80b", 3, KeyBackspace, 2), "ab")
  equals("a rune cut short by the end of the buffer",
         afterKeys("ab\xE2\x80", 4, KeyBackspace), "ab\xE2")

quit(if failures > 0: 1 else: 0)
