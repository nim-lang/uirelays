## Tests for the layout: the division of a window into named rects, the
## borders between them as things a pointer can take hold of, and the way back
## to text. Needs no window -- all of it is arithmetic on a rectangle.

import std/[tables, strutils]
import uirelays/[coords, layout]

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc parsed(src: string): Layout =
  result = parseLayout(src)
  check("parses: " & src.splitLines[0], result.error.len == 0, result.error)

const Window = """
(layout
  (cols
    (sidebar (px 200))
    (editor)
    (panel (px 100)))
  (status (lines 1)))
"""

let m = LayoutMetrics(screenW: 1000, screenH: 800, lineHeight: 20, padding: 5,
                      gap: 4, uiScale: 100)

proc spanOf(l: Layout; name: string; vertical = false): string =
  let cells = l.resolve(m)
  if name notin cells: return "missing"
  let r = cells[name]
  result = if vertical: $r.y & "+" & $r.h else: $r.x & "+" & $r.w

# ---------------------------------------------------------------------------
echo "resolving:"
# ---------------------------------------------------------------------------

block:
  let l = parsed(Window)
  # (lines 1) is one line plus the padding above and below it; the row above
  # takes what is left, less the gap between them.
  equals("a lines box is its lines and its padding",
         l.spanOf("status", vertical = true), "770+30")
  equals("and the box above it takes the rest",
         l.spanOf("sidebar", vertical = true), "0+766")
  equals("a px box is its pixels", l.spanOf("sidebar"), "0+200")
  equals("the stretching one takes what the gaps leave",
         l.spanOf("editor"), "204+692")
  equals("and the last one starts behind it", l.spanOf("panel"), "900+100")

block:
  # A `(px N)` is logical, so the same layout describes the same window on a
  # display of any density: at 200% the sidebar takes twice the pixels and the
  # stretching neighbour keeps whatever that leaves.
  let l = parsed("(layout (cols (sidebar (px 30)) (editor)))")
  let normal = l.resolve(100, 100, lineHeight = 10, padding = 0)
  let dense = l.resolve(100, 100, lineHeight = 10, padding = 0, uiScale = 200)
  equals("a px size is logical",
         $normal["sidebar"].w & " -> " & $dense["sidebar"].w, "30 -> 60")
  equals("and the stretching neighbour gives way",
         $normal["editor"].w & " -> " & $dense["editor"].w, "70 -> 40")
  equals("the dense sidebar still starts at the left edge",
         $dense["sidebar"].x & "," & $dense["editor"].x, "0,60")

# ---------------------------------------------------------------------------
echo "finding a border:"
# ---------------------------------------------------------------------------

proc shows(s: Splitter): string =
  if not s.found: "nothing"
  else: (if s.vertical: "rows" else: "cols") & " " & $s.parent & " before " &
        $s.before

block:
  let l = parsed(Window)
  equals("the border between the first two columns",
         l.splitterAt(m, 202, 400).shows, "cols @[0] before 0")
  equals("the one behind the stretching box",
         l.splitterAt(m, 898, 400).shows, "cols @[0] before 1")
  equals("and the one across the window",
         l.splitterAt(m, 500, 768).shows, "rows @[] before 0")
  equals("the middle of a box is not a border",
         l.splitterAt(m, 500, 400).shows, "nothing")
  equals("nor is the edge of the window",
         l.splitterAt(m, 0, 0).shows, "nothing")
  # The gap is four pixels and the slack two, so eight are catchable in all.
  equals("a pointer just short of a border still catches it",
         l.splitterAt(m, 199, 400).shows, "cols @[0] before 0")
  equals("and one just past it", l.splitterAt(m, 205, 400).shows,
         "cols @[0] before 0")
  equals("three pixels off it is a miss", l.splitterAt(m, 196, 400).shows,
         "nothing")
  let r = l.splitterRect(m, l.splitterAt(m, 202, 400))
  equals("the border is the gap itself",
         $r.x & "+" & $r.w & " by " & $r.y & "+" & $r.h, "200+4 by 0+766")

block:
  # A border inside a box belongs to that box, not to the one it sits in.
  let l = parsed("""
(layout
  (cols
    (rows (px 200)
      (tabs (lines 6))
      (explorer))
    (editor)))
""")
  equals("a nested border names the box it divides",
         l.splitterAt(m, 100, 132).shows, "rows @[0, 0] before 0")
  equals("and the outer one is still the outer one",
         l.splitterAt(m, 202, 400).shows, "cols @[0] before 0")

# ---------------------------------------------------------------------------
echo "moving one:"
# ---------------------------------------------------------------------------

block:
  var l = parsed(Window)
  let s = l.splitterAt(m, 202, 400)
  check("the drag took", l.dragTo(m, s, 300, 400))
  # The pointer came down two pixels into the border and moved 98, so the
  # border moved 98 as well -- it does not jump to the pointer on being
  # touched.
  equals("the box before it moved by what the pointer moved",
         l.spanOf("sidebar"), "0+298")
  equals("its neighbour gave up exactly that much",
         l.spanOf("editor"), "302+594")
  equals("and the box past that one did not move",
         l.spanOf("panel"), "900+100")
  equals("the size is written in the unit it was written in",
         $l, """
(layout
  (cols
    (sidebar (px 298))
    (editor)
    (panel (px 100)))
  (status (lines 1)))
""")

block:
  var l = parsed(Window)
  let s = l.splitterAt(m, 500, 768)
  check("a row border moves in y", l.dragTo(m, s, 500, 700))
  # `status` is counted in lines, so it lands on a whole number of them: 800
  # less the 700 the drag asked for is 100, which is four lines and the
  # padding rather than the 96 that were asked for.
  equals("a lines box snaps to whole lines",
         l.spanOf("status", vertical = true), "710+90")
  check("and says so as lines", ($l).contains("(status (lines 4))"), $l)

block:
  var l = parsed("(layout (cols (a) (b) (c)))")
  let s = l.splitterAt(m, 332, 400)
  check("two stretching boxes can be dragged apart",
        l.dragTo(m, s, 200, 400))
  equals("the one before the border takes what was asked",
         l.spanOf("a"), "0+198")
  equals("the one behind it takes the rest of the pair",
         l.spanOf("b"), "202+462")
  # To the pixel: the weights a drag writes divide back into the very sizes
  # they were taken from, so the boxes nobody touched do not creep.
  equals("and the third is left exactly where it was",
         l.spanOf("c"), "668+332")
  check("the weights say the window they are in",
        ($l).contains("(a (stretch"), $l)

block:
  var l = parsed(Window)
  let s = l.splitterAt(m, 202, 400)
  check("a border cannot be dragged past the window",
        l.dragTo(m, s, -500, 400))
  check("the box keeps a few pixels to be caught by",
        l.resolve(m)["sidebar"].w >= 8, $l.resolve(m)["sidebar"].w)
  check("and its neighbour has the rest",
        l.resolve(m)["editor"].w > 800, $l.resolve(m)["editor"].w)

block:
  var l = parsed(Window)
  let nothing = l.splitterAt(m, 500, 400)
  check("dragging nothing changes nothing", not l.dragTo(m, nothing, 1, 1))
  let s = l.splitterAt(m, 202, 400)
  check("and neither does a drag that lands where it started",
        not l.dragTo(m, s, 202, 400))

# ---------------------------------------------------------------------------
echo "writing one back:"
# ---------------------------------------------------------------------------

block:
  let l = parsed(Window)
  equals("what comes out is what went in", $l, Window)
  let again = parsed($l)
  equals("and it reads back as the same window",
         $again.resolve(m).len & " cells", "4 cells")
  equals("with everything in the same place", again.spanOf("editor"),
         l.spanOf("editor"))

block:
  let l = parsed("(layout (rows (a (stretch 3)) (cols (b) (c (px 10)))))")
  equals("a nested layout keeps its shape", $l, """
(layout
  (rows
    (a (stretch 3))
    (cols
      (b)
      (c (px 10)))))
""")

block:
  let broken = parseLayout("(layout (cols (a) (px 3)))")
  check("a layout that did not parse is not written", $broken == "",
        $broken)
  check("and resolves to nothing", broken.resolve(m).len == 0)

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
