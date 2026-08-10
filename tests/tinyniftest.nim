## Tests for the NIF lexer and the layout parser built on top of it.
## Neither needs a window, so this runs anywhere.

import std/[tables, strutils]
import uirelays/[tinynif, layout, coords]

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc tokens(src: string): seq[Token] =
  ## Every token of `src`, up to and including the one that ends the stream.
  result = @[]
  var lex = initLexer(src)
  while true:
    let tok = next(lex)
    result.add tok
    if tok.kind == tkEof or tok.kind == tkError: break

proc kinds(src: string): string =
  result = ""
  for tok in tokens(src):
    if result.len > 0: result.add " "
    result.add $tok.kind

proc firstError(src: string): string =
  for tok in tokens(src):
    if tok.kind == tkError: return tok.position & ": " & tok.text
  result = ""

# ---------------------------------------------------------------------------
echo "lexer:"
# ---------------------------------------------------------------------------

equals("a tree", kinds("(add 3 4)"), "tkParLe tkIntLit tkIntLit tkParRi tkEof")
equals("nesting", kinds("(a (b) (c))"),
       "tkParLe tkParLe tkParRi tkParLe tkParRi tkParRi tkEof")

block:
  let t = tokens("(cell explorer)")
  equals("the tag is the ParLe's text", t[0].text, "cell")
  equals("an ident", t[1].text, "explorer")
  check("an ident is an ident", t[1].kind == tkIdent)

block:
  let t = tokens("foo.3.mymod :bar.1 . plain")
  check("a dotted name is a symbol", t[0].kind == tkSymbol, $t[0].kind)
  equals("the symbol keeps its dots", t[0].text, "foo.3.mymod")
  check("a ':' marks a definition", t[1].kind == tkSymbolDef, $t[1].kind)
  equals("the ':' is not part of the name", t[1].text, "bar.1")
  check("a lone dot is the empty node", t[2].kind == tkDot, $t[2].kind)
  check("everything else is an ident", t[3].kind == tkIdent, $t[3].kind)

block:
  let t = tokens("0 42 -7 +7 0xFF 255u")
  check("zero", t[0].kind == tkIntLit and t[0].intVal == 0)
  check("decimal", t[1].intVal == 42, $t[1].intVal)
  check("negative", t[2].intVal == -7, $t[2].intVal)
  check("explicit plus", t[3].intVal == 7, $t[3].intVal)
  check("hexadecimal", t[4].kind == tkIntLit and t[4].intVal == 255, $t[4].intVal)
  check("a 'u' suffix is tolerated", t[5].kind == tkIntLit and t[5].intVal == 255,
        $t[5].kind & " " & $t[5].intVal)

block:
  let t = tokens("- -x")
  check("a lone '-' is a name", t[0].kind == tkIdent, $t[0].kind)
  check("so is '-x'", t[1].kind == tkIdent and t[1].text == "-x", $t[1].text)

block:
  let t = tokens("\"plain\" \"tab\\09end\" \"\" \"a\\5Cb\\22c\"")
  equals("a string literal", t[0].text, "plain")
  equals("a hex escape", t[1].text, "tab\tend")
  check("the empty string", t[2].kind == tkStringLit and t[2].text.len == 0)
  equals("backslash and quote as escapes", t[3].text, "a\\b\"c")

block:
  let t = tokens("'a' '\\0A'")
  check("a character literal", t[0].kind == tkCharLit and t[0].intVal == 97,
        $t[0].intVal)
  check("an escaped character", t[1].kind == tkCharLit and t[1].intVal == 10,
        $t[1].intVal)

equals("a comment runs to the end of the line",
       kinds("(a # this is ignored\n 1)"), "tkParLe tkIntLit tkParRi tkEof")
equals("a comment may be the whole input", kinds("# nothing else\n"), "tkEof")
equals("whitespace only", kinds("  \t\r\n  "), "tkEof")

block:
  # The end keeps repeating instead of running off the string.
  var lex = initLexer("()x")
  discard next(lex)
  discard next(lex)
  discard next(lex)
  check("Eof repeats", next(lex).kind == tkEof and next(lex).kind == tkEof)

block:
  let t = tokens("(a\n  (b 1))")
  check("line and column of a nested tag",
        t[1].line == 2 and t[1].col == 3,
        $t[1].line & ":" & $t[1].col)

echo "lexer errors:"
check("an unterminated string", firstError("\"oops").endsWith("unterminated string literal"),
      firstError("\"oops"))
check("a newline inside a string",
      firstError("\"oops\nmore\"").len > 0, "accepted")
check("a half-written escape",
      firstError("\"a\\zz\"").contains("two hex digits"), firstError("\"a\\zz\""))
check("a float literal is named, not truncated",
      firstError("1.5").contains("floating point"), firstError("1.5"))
check("no tag behind '('", firstError("( a)").contains("expected a tag"),
      firstError("( a)"))
check("'()' has no tag", firstError("()").contains("expected a tag"),
      firstError("()"))
check("junk stuck to a number",
      firstError("12ab").contains("integer literal"), firstError("12ab"))
check("an integer too large for int64",
      firstError("99999999999999999999").contains("too large"),
      firstError("99999999999999999999"))
check("an unclosed character literal",
      firstError("'ab'").contains("apostrophe"), firstError("'ab'"))
equals("the error carries its position", firstError("(a\n  1.5)").split(":")[0] & ":" &
       firstError("(a\n  1.5)").split(":")[1], "2:3")

# ---------------------------------------------------------------------------
echo "layout:"
# ---------------------------------------------------------------------------

proc parsed(src: string): Layout =
  result = parseLayout(src)
  check("parses: " & src.splitLines[0], result.error.len == 0, result.error)

proc rectStr(r: Rect): string =
  result = $r.x & "," & $r.y & " " & $r.w & "x" & $r.h

proc cellStr(cells: Table[string, Rect]; name: string): string =
  result = if name in cells: rectStr(cells[name]) else: "(missing)"

block:
  let l = parsed("""
(layout
  (top (px 30))
  (mid)
  (bot (lines 2)))
""")
  let cells = l.resolve(100, 200, lineHeight = 10, padding = 0)
  equals("a fixed pixel height", cells.cellStr("top"), "0,0 100x30")
  equals("the stretch gets what is left", cells.cellStr("mid"), "0,30 100x150")
  equals("lines times lineHeight", cells.cellStr("bot"), "0,180 100x20")

block:
  let l = parsed("(layout (a (lines 1)) (b))")
  let cells = l.resolve(100, 200, lineHeight = 10, padding = 6)
  equals("padding surrounds a lines cell", cells.cellStr("a"), "0,0 100x22")
  equals("and comes off the stretch", cells.cellStr("b"), "0,22 100x178")

block:
  let l = parsed("(layout (cols (a (stretch 1)) (b (stretch 3))))")
  let cells = l.resolve(100, 50, lineHeight = 10, padding = 0)
  equals("weighted share", cells.cellStr("a"), "0,0 25x50")
  equals("the larger weight", cells.cellStr("b"), "25,0 75x50")

block:
  let l = parsed("(layout (cols (a) (b) (c)))")
  let cells = l.resolve(100, 10, lineHeight = 10, padding = 0)
  # 100 does not divide by 3: the last one takes the remainder so that the
  # children fill their parent exactly.
  equals("thirds, first", cells.cellStr("a"), "0,0 33x10")
  equals("thirds, second", cells.cellStr("b"), "33,0 33x10")
  equals("thirds, third fills the rest", cells.cellStr("c"), "66,0 34x10")

block:
  let l = parsed("(layout (a (px 10)) (b))")
  let cells = l.resolve(100, 100, lineHeight = 10, padding = 0, gap = 2)
  equals("a gap sits between the boxes", cells.cellStr("a"), "0,0 100x10")
  equals("and comes off the stretch too", cells.cellStr("b"), "0,12 100x88")

block:
  # The editor's own layout: rows inside cols inside rows.
  let l = parsed("""
(layout
  (title (lines 1))
  (cols
    (rows (px 200)
      (tabs (lines 6))
      (explorer))
    (editor (stretch 3))
    (rows (stretch 2)
      (history (lines 5))
      (terminal)))
  (status (lines 1)))
""")
  let cells = l.resolve(1000, 500, lineHeight = 10, padding = 0)
  equals("title", cells.cellStr("title"), "0,0 1000x10")
  equals("status", cells.cellStr("status"), "0,490 1000x10")
  equals("a column keeps its pixel width", cells.cellStr("tabs"), "0,10 200x60")
  equals("below it, the rest of the column", cells.cellStr("explorer"),
         "0,70 200x420")
  equals("the middle column by weight", cells.cellStr("editor"),
         "200,10 480x480")
  equals("the right column, top", cells.cellStr("history"), "680,10 320x50")
  equals("the right column, bottom", cells.cellStr("terminal"),
         "680,60 320x430")

  check("cell() finds a leaf", l.cell("terminal"))
  check("cell() does not invent one", not l.cell("nosuchthing"))

  let hit = cells.hitTest(300, 100)
  equals("hitTest names the cell", hit.name, "editor")
  equals("hitTest is relative to it", $hit.pos.x & "," & $hit.pos.y, "100,90")

block:
  let l = parsed("""
# The layout of a window, commented.
(layout
  (header (lines 2))   # a title bar
  (body))
""")
  let cells = l.resolve(80, 100, lineHeight = 10, padding = 0)
  equals("comments do not disturb the layout", cells.cellStr("header"),
         "0,0 80x20")
  equals("nor the box behind them", cells.cellStr("body"), "0,20 80x80")

block:
  # A widget name is a tag, so it may contain whatever a tag may contain.
  let l = parsed("(layout (side-bar) (main.view))")
  let cells = l.resolve(10, 10)
  check("a dash in a name", "side-bar" in cells, "names: " & $cells.len)
  check("a dot in a name", "main.view" in cells, "names: " & $cells.len)

block:
  # The structural tags are the names a widget cannot have: `rows` here is an
  # empty container, not a cell called "rows".
  let l = parsed("(layout (rows) (real))")
  check("'rows' is not a widget name", not l.cell("rows"))
  check("but its sibling is", l.cell("real"))

echo "layout errors:"

proc layoutError(src: string): string =
  result = parseLayout(src).error

proc rejects(name, src, expected: string) =
  let err = layoutError(src)
  check(name, err.contains(expected), "got '" & err & "'")

rejects("a misspelled container", "(layout (col (a) (b)))", "'col' names a widget")
rejects("a nameless box", "(layout ())", "expected a tag")
rejects("a missing ')'", "(layout (a)", "expected ')'")
rejects("a stray ')'", "(layout (a)))", "behind the layout")
rejects("something behind the layout", "(layout (a)) (b)", "behind the layout")
rejects("a size behind the children", "(layout (rows (a) (px 3)))",
        "before the children")
rejects("two sizes", "(layout (a (px 3) (px 4)))", "only one size")
rejects("a negative size", "(layout (a (px -3)))", "cannot be negative")
rejects("a size without a number", "(layout (a (px)))", "expected a number")
rejects("a nested layout", "(layout (layout (a)))", "outermost")
rejects("another tag at the top", "(rows (a))", "expected (layout ...)")
rejects("an empty input", "", "nothing here")
rejects("comments only", "# just a note\n", "nothing here")
rejects("a lexer error is passed along", "(layout (a (px 1.5)))",
        "floating point")

block:
  # A layout that did not parse resolves to nothing at all, so a caller that
  # ignores `error` gets an empty window rather than a wrong one.
  let bad = parseLayout("(layout (a (px 3) (px 4)))")
  check("a broken layout resolves to nothing", bad.resolve(100, 100).len == 0)
  check("and claims no cells", not bad.cell("a"))
  let empty = Layout()
  check("so does a layout nobody parsed into", empty.resolve(100, 100).len == 0)

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
