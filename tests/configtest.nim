## Tests for `(config ...)`: the layout and the theme in one file, and the
## refusal of a theme nobody could read. Needs no window.

import std/[tables, strutils]
import uirelays/screen  # Color, which config only passes through
import widgets/config

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc `$`(c: Color): string =
  result = $c.r & "," & $c.g & "," & $c.b

proc parsed(src: string): Config =
  result = parseConfig(src)
  check("parses: " & src.splitLines[0], result.error.len == 0, result.error)

# ---------------------------------------------------------------------------
echo "config:"
# ---------------------------------------------------------------------------

block:
  let c = parsed("""
(config
  (layout
    (editor (stretch 3))
    (status (lines 1)))
  (theme
    (bg "1E1E2E")
    (fg "CDD6F4"
      (Keyword "CBA6F7")
      (Comment "6C7086"))
    (selBg "585b70")))
""")
  let cells = c.layout.resolve(100, 100, lineHeight = 10, padding = 0)
  check("the layout came through", "editor" in cells and "status" in cells,
        $cells.len & " cells")
  equals("a scalar color", $c.theme.bg, "30,30,46")
  equals("the fg base", $c.theme.fg[TokenClass.Identifier], "205,214,244")
  equals("a token class override", $c.theme.fg[TokenClass.Keyword],
         "203,166,247")
  equals("another one", $c.theme.fg[TokenClass.Comment], "108,112,134")
  equals("lower case is fine too", $c.theme.selBg, "88,91,112")
  equals("no complaint", c.note, "")

block:
  let c = parsed("(config (theme (bg \"14141E\")) (layout (editor)))")
  check("theme before layout", c.layout.cell("editor"))
  equals("and both took effect", $c.theme.bg, "20,20,30")

block:
  let c = parsed("(config (layout (editor)))")
  let d = defaultTheme()
  equals("a config without a theme keeps the fallback", $c.theme.bg, $d.bg)
  equals("all of it", $c.theme.fg[TokenClass.Keyword], $d.fg[TokenClass.Keyword])

block:
  let c = parsed("(config (theme (bg \"1E1E2E\")))")
  check("a config without a layout is empty, not broken",
        c.layout.resolve(100, 100).len == 0)

block:
  var base = defaultTheme()
  base.markerBg = color(1, 2, 3)
  let c = parseConfig("(config (theme (bg \"1E1E2E\")))", base)
  equals("what the theme leaves out comes from the fallback given",
         $c.theme.markerBg, "1,2,3")

block:
  # Every field of Theme has to be reachable from the file. Each one gets its
  # own color here, so a field that is wired to the wrong place shows up.
  let c = parsed("""
(config (theme
  (bg "0A141E")
  (fg "C8C8C8"
    (Keyword "FF6464")
    (Comment "969696")
    (MarkdownFence "8C8C91"))
  (selBg "28292A")
  (bracketBg "2B2C2D")
  (cursorColor "FF0000")
  (lineNumColor "00FF00")
  (markerBg "2E2F30")
  (scrollBarColor "313233")
  (scrollBarActiveColor "343536")
  (scrollTrackColor "373839")
  (activeLineBg "3A3B3C")
  (actionColor "3D3E3F")
  (closeColor "6464FF")))
""")
  equals("bg", $c.theme.bg, "10,20,30")
  equals("fg base", $c.theme.fg[TokenClass.Text], "200,200,200")
  equals("fg Keyword", $c.theme.fg[TokenClass.Keyword], "255,100,100")
  equals("fg Comment", $c.theme.fg[TokenClass.Comment], "150,150,150")
  equals("fg MarkdownFence", $c.theme.fg[TokenClass.MarkdownFence],
         "140,140,145")
  equals("selBg", $c.theme.selBg, "40,41,42")
  equals("bracketBg", $c.theme.bracketBg, "43,44,45")
  equals("cursorColor", $c.theme.cursorColor, "255,0,0")
  equals("lineNumColor", $c.theme.lineNumColor, "0,255,0")
  equals("markerBg", $c.theme.markerBg, "46,47,48")
  equals("scrollBarColor", $c.theme.scrollBarColor, "49,50,51")
  equals("scrollBarActiveColor", $c.theme.scrollBarActiveColor, "52,53,54")
  equals("scrollTrackColor", $c.theme.scrollTrackColor, "55,56,57")
  equals("activeLineBg", $c.theme.activeLineBg, "58,59,60")
  equals("actionColor", $c.theme.actionColor, "61,62,63")
  equals("closeColor", $c.theme.closeColor, "100,100,255")
  equals("a whole theme, and still readable", c.note, "")

block:
  let c = parsed("""
(config          # a comment
  (layout (editor))   # and another
  (theme (bg "1E1E2E")))
""")
  check("comments are allowed throughout", c.layout.cell("editor"))
  equals("and change nothing", $c.theme.bg, "30,30,46")

# ---------------------------------------------------------------------------
echo "contrast:"
# ---------------------------------------------------------------------------

check("black on white is the textbook 21:1",
      contrast(color(0, 0, 0), color(255, 255, 255)) == 2100,
      ratioText(contrast(color(0, 0, 0), color(255, 255, 255))))
check("a color against itself is 1:1",
      contrast(color(30, 30, 46), color(30, 30, 46)) == 100)
check("the order does not matter",
      contrast(color(10, 20, 30), color(200, 210, 220)) ==
      contrast(color(200, 210, 220), color(10, 20, 30)))
check("the default theme passes its own test",
      contrastProblem(defaultTheme()).len == 0, contrastProblem(defaultTheme()))
check("goldenDusk passes it", contrastProblem(goldenDusk()).len == 0,
      contrastProblem(goldenDusk()))
check("catppuccinMocha still does too",
      contrastProblem(catppuccinMocha()).len == 0,
      contrastProblem(catppuccinMocha()))

block:
  # Near-black text on a near-black background: the case the check exists for.
  let c = parsed("(config (layout (editor)) (theme (bg \"000000\") " &
                 "(fg \"141414\")))")
  check("an unreadable theme is refused", c.note.len > 0)
  check("with the sentence the status bar wants",
        c.note.startsWith("too low contrast between colors, used default " &
                          "settings instead"), c.note)
  check("and it says which color", c.note.contains(":1 against the background"),
        c.note)
  equals("the theme is the fallback", $c.theme.bg, $defaultTheme().bg)
  check("the layout is kept -- only the colors were refused",
        c.layout.cell("editor"))
  equals("this is a note, not an error", c.error, "")

block:
  # The classic half-finished edit: a new background, the old foregrounds.
  let c = parsed("(config (theme (bg \"FFFFFF\")))")
  check("light background with dark-theme text is refused", c.note.len > 0,
        "accepted")

block:
  let c = parsed("(config (theme (bg \"1E1E2E\") (cursorColor \"202030\")))")
  check("an invisible cursor is refused", c.note.len > 0, "accepted")
  check("and named", c.note.contains("cursor"), c.note)

block:
  let c = parsed("(config (theme (bg \"1E1E2E\") (lineNumColor \"1F1F2F\")))")
  check("invisible line numbers are refused", c.note.len > 0, "accepted")

block:
  # Backgrounds are not checked: they sit behind text on purpose.
  let c = parsed("(config (theme (bg \"1E1E2E\") (activeLineBg \"1F1F2F\") " &
                 "(selBg \"202030\") (actionColor \"212131\")))")
  equals("a background close to bg is nobody's business", c.note, "")

block:
  # One class alone is enough to refuse the theme.
  let c = parsed("(config (theme (bg \"1E1E2E\") (fg (Keyword \"212132\"))))")
  check("a single unreadable token class is refused", c.note.len > 0,
        "accepted")
  check("named by the class", c.note.contains("Keyword"), c.note)

echo "config errors:"

proc rejects(name, src, expected: string) =
  let err = parseConfig(src).error
  check(name, err.contains(expected), "got '" & err & "'")

rejects("an unknown theme field", "(config (theme (bgg \"010203\")))",
        "'bgg' is not a theme field")
rejects("an unknown token class", "(config (theme (fg (Keywrd \"010203\"))))",
        "'Keywrd' is not a token class")
rejects("numbers are not a color", "(config (theme (bg 30 30 46)))",
        "expected a color like")
rejects("too few digits", "(config (theme (bg \"1E1E2\")))",
        "six hex digits")
rejects("too many digits", "(config (theme (bg \"1E1E2E00\")))",
        "six hex digits")
rejects("a '#' in the string", "(config (theme (bg \"#1E1E2E\")))",
        "six hex digits")
rejects("a digit that is not hex", "(config (theme (bg \"1E1E2Z\")))",
        "six hex digits")
rejects("the empty string", "(config (theme (bg \"\")))", "six hex digits")
rejects("two colors in one field",
        "(config (theme (bg \"1E1E2E\" \"112233\")))", "expected ')'")
rejects("two layouts", "(config (layout (a)) (layout (b)))",
        "only one (layout ...)")
rejects("two themes",
        "(config (theme (bg \"010101\")) (theme (bg \"020202\")))",
        "only one (theme ...)")
rejects("a tag that belongs nowhere", "(config (style (bg \"010203\")))",
        "does not belong in a config")
rejects("a bare layout", "(layout (a))", "expected (config ...)")
rejects("nothing at all", "", "nothing here")
rejects("an unclosed config", "(config (layout (a))", "expected ')'")
rejects("something behind the config", "(config (layout (a))) (config)",
        "behind the config")
rejects("a layout error is passed along", "(config (layout (grid (a))))",
        "names a widget")
rejects("a lexer error is passed along",
        "(config (theme (bg \"1E1E2E)))", "unterminated string")

block:
  # A config that did not parse hands back nothing usable, so a caller that
  # ignores `error` cannot draw a half-applied window.
  let bad = parseConfig("(config (theme (bgg \"010203\")) (layout (editor)))")
  check("a broken config has no layout", bad.layout.resolve(100, 100).len == 0)
  equals("and the fallback theme", $bad.theme.bg, $defaultTheme().bg)

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
