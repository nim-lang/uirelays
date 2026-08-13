## `(Comment "#7A7365" (italics))` -- does the token actually come out in
## another font? The relays are replaced by stubs that record every openFont
## and every drawText, so this watches SynEdit's own drawing path and needs no
## window and no driver.
import std/tables
import uirelays/[screen, coords, input]
import widgets/[synedit, theme]

var
  nextHandle = 0
  openedWith: Table[int, string]          ## handle -> "16 {bold}"
  drawn: seq[tuple[font: int, text: string]]

fontRelays = FontRelays(
  openFont: proc (path: string; size: int; style: FontStyles;
                  metrics: var FontMetrics): Font =
    inc nextHandle
    openedWith[nextHandle] = $size & " " & $style
    metrics = FontMetrics(ascent: 12, descent: 4, lineHeight: 16)
    Font(nextHandle),
  closeFont: proc (f: Font) = discard,
  getFontMetrics: proc (f: Font): FontMetrics =
    FontMetrics(ascent: 12, descent: 4, lineHeight: 16),
  measureText: proc (f: Font; text: string): TextExtent =
    TextExtent(w: text.len * 8, h: 16),
  drawText: proc (f: Font; x, y: int; text: string;
                  fg, bg: Color): TextExtent =
    if text.len > 0: drawn.add (f.int, text)
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

var th = defaultTheme()
th.style[TokenClass.Comment] = {FontStyle.italics}
th.style[TokenClass.Keyword] = {FontStyle.bold}

var ed = createSynEdit(font, th)
ed.setText("proc main =\n  # a comment\n  echo 42\n")

var e = default(Event)
discard ed.draw(e, rect(0, 0, 400, 200), focused = true)

echo "font styles:"

var fails = 0
proc check(name: string; cond: bool; detail = "") =
  if cond: echo "  PASS  ", name
  else:
    inc fails
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc fontOf(text: string): int =
  result = 0
  for d in drawn:
    if d.text == text: return d.font

let plain = font.int
check("the comment is drawn with a font of its own",
      fontOf("# a comment") != 0 and fontOf("# a comment") != plain,
      $fontOf("# a comment"))
check("and that font was opened as italics",
      openedWith.getOrDefault(fontOf("# a comment")) == "16 {italics}",
      openedWith.getOrDefault(fontOf("# a comment")))
check("the keyword is drawn with the bold one",
      openedWith.getOrDefault(fontOf("proc")) == "16 {bold}",
      openedWith.getOrDefault(fontOf("proc")))
check("an unstyled class keeps the plain font", fontOf("echo") == plain or
      openedWith.getOrDefault(fontOf("echo")) == "16 {}",
      $fontOf("echo"))
check("the number too", fontOf("42") == plain, $fontOf("42"))
check("no font was opened twice", nextHandle == 3, $nextHandle)

# Take the styles away again: the same theme edit a user makes in [config].
th.style[TokenClass.Comment] = {}
th.style[TokenClass.Keyword] = {}
ed.theme = th
drawn.setLen 0
discard ed.draw(e, rect(0, 0, 400, 200), focused = true)
check("dropping the styles puts everything back on the plain font",
      fontOf("# a comment") == plain and fontOf("proc") == plain)
check("and opened nothing new", nextHandle == 3, $nextHandle)

echo(if fails == 0: "ALL PASS" else: $fails & " FAILURE(S)")
if fails > 0: quit 1
