## Tests for `(state ...)`: the font sizes and box sizes the mouse set, in the
## file the app writes and nobody edits. Needs no window.

import std/[tables, strutils]
import widgets/state

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc parsed(src: string): UiState =
  result = parseState(src)
  check("parses: " & src.splitLines[0], result.error.len == 0, result.error)

# ---------------------------------------------------------------------------
echo "state:"
# ---------------------------------------------------------------------------

block:
  let st = parsed("""
(state
  (fonts (editor 18) (terminal 13))
  (sizes
    (box (path 0 0) (px 240))
    (box (path 0 1 2) (lines 8))))
""")
  equals("a font size", $st.fontSize("editor", 16), "18")
  equals("another one", $st.fontSize("terminal", 16), "13")
  equals("a cell nobody sized falls back", $st.fontSize("tabs", 16), "16")
  equals("a size by path", $st.sizes[@[0, 0]], "(px 240)")
  equals("a deeper path", $st.sizes[@[0, 1, 2]], "(lines 8)")
  check("and nothing else", st.sizes.len == 2, $st.sizes.len)

block:
  let st = parsed("(state)")
  check("an empty state has no fonts", st.fonts.len == 0)
  check("and no sizes", st.sizes.len == 0)
  equals("so every cell falls back", $st.fontSize("editor", 16), "16")

block:
  let st = parsed("(state (fonts) (sizes))")
  check("empty sections are empty", st.fonts.len == 0 and st.sizes.len == 0)

block:
  # A comment is the only thing in here a person would ever write.
  let st = parsed("""
# focim writes this file; the window itself is in config.nif.
(state
  (fonts (editor 20)))
""")
  equals("comments do not disturb it", $st.fontSize("editor", 16), "20")

block:
  var st = UiState(fonts: initTable[string, int](),
                   sizes: initTable[BoxPath, CellSize]())
  st.fonts["terminal"] = 13
  st.fonts["editor"] = 18
  st.sizes[@[0, 2]] = CellSize(kind: skStretch, value: 357)
  st.sizes[@[0, 0, 0]] = CellSize(kind: skLines, value: 8)
  st.sizes[@[0, 1]] = CellSize(kind: skStretch, value: 643)
  # Sorted, so that the file does not reshuffle itself on every save.
  equals("what gets written", $st, """
# focim writes this file; the window itself is in config.nif.
(state
  (fonts
    (editor 18)
    (terminal 13))
  (sizes
    (box (path 0 0 0) (lines 8))
    (box (path 0 1) (stretch 643))
    (box (path 0 2) (stretch 357))))
""")
  let back = parsed($st)
  check("and reads back the same fonts", back.fonts == st.fonts)
  check("and the same sizes", back.sizes == st.sizes)

block:
  var st = UiState(fonts: initTable[string, int](),
                   sizes: initTable[BoxPath, CellSize]())
  let back = parsed($st)
  check("an empty state survives the round trip too",
        back.fonts.len == 0 and back.sizes.len == 0, $st)

# ---------------------------------------------------------------------------
echo "state errors:"
# ---------------------------------------------------------------------------

proc rejects(name, src, expected: string) =
  let st = parseState(src)
  check(name, st.error.contains(expected), "got '" & st.error & "'")
  # Nothing at all is used from a file that did not parse: half a session's
  # worth of splitter positions is worse than none.
  check(name & ", and nothing is kept",
        st.fonts.len == 0 and st.sizes.len == 0)

rejects("an empty file", "", "nothing here")
rejects("another tag at the top", "(fonts (editor 16))", "expected (state ...)")
rejects("a section that is not one", "(state (colors (bg 1)))",
        "does not belong in a state")
rejects("two font sections", "(state (fonts) (fonts))", "only one (fonts ...)")
rejects("two size sections", "(state (sizes) (sizes))", "only one (sizes ...)")
rejects("a font size that is not a number", "(state (fonts (editor big)))",
        "expected a number")
rejects("a negative font size", "(state (fonts (editor -3)))",
        "not negative")
rejects("a box without a path", "(state (sizes (box (px 3))))",
        "expected (path ...)")
rejects("an empty path", "(state (sizes (box (path) (px 3))))",
        "at least one step")
rejects("a box without a size", "(state (sizes (box (path 0))))",
        "expected a size")
rejects("a size that is not one", "(state (sizes (box (path 0) (wide 3))))",
        "not a size")
rejects("something other than a box", "(state (sizes (cell 1)))",
        "expected (box ...)")
rejects("a missing ')'", "(state (fonts (editor 16))", "expected ')'")
rejects("something behind the state", "(state) (state)", "behind the state")
rejects("a lexer error is passed along", "(state (fonts (editor 1.5)))",
        "floating point")

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
