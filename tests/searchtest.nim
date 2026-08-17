## Tests for search and replace: what counts as a match, where the finger
## starts, and that replacing one match leaves the others pointing at the right
## places. Needs no window -- nothing here draws, and a SynEdit needs no font
## until something does.

import std/strutils
import uirelays/screen  # Font, which SynEdit only draws with
import widgets/[synedit, search]

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc buffer(text: string): SynEdit =
  result = createSynEdit(Font(0))
  result.lang = langNone
  result.setText(text)

proc hitsOf(text, term: string; opts = ""): string =
  ## The matched ranges, as `a..b` each, so a test can name what it expects.
  var ed = buffer(text)
  var parts: seq[string] = @[]
  for h in findHits(ed, term, parseSearchOptions(opts)):
    parts.add $h.a & ".." & $h.b
  result = parts.join(" ")

# ---------------------------------------------------------------------------
echo "search:"
# ---------------------------------------------------------------------------

block:
  equals("every occurrence", hitsOf("abc abc abc", "abc"), "0..2 4..6 8..10")
  equals("nothing found is no hit", hitsOf("abc", "xyz"), "")
  equals("an empty term finds nothing", hitsOf("abc", ""), "")
  equals("case is ignored by default", hitsOf("Foo foo FOO", "foo"),
         "0..2 4..6 8..10")
  equals("until it is asked for", hitsOf("Foo foo FOO", "foo", "c"), "4..6")
  # `aa` in `aaa` twice would mean the second hit overlaps the first, and a
  # replace would then eat what the one before it just wrote.
  equals("matches do not overlap", hitsOf("aaaa", "aa"), "0..1 2..3")

block:
  equals("a word may sit anywhere by default", hitsOf("foobar foo", "foo"),
         "0..2 7..9")
  equals("whole words only", hitsOf("foobar foo", "foo", "w"), "7..9")
  equals("and the letters around it are what decide",
         hitsOf("x_foo foo. foo", "foo", "w"), "6..8 11..13")
  # Otherwise `f i` would answer with every third character in the file.
  equals("a single letter is a word without being asked",
         hitsOf("i in if i", "i"), "0..0 8..8")

block:
  # The finger starts at the cursor, not at the top: a search is made where
  # one is looking.
  var ed = buffer("abc abc abc")
  ed.gotoPos(4)
  var bs = BufferSearch()
  bs.run(ed, "abc", {})
  check("the first hit at or after the cursor", bs.active == 1, $bs.active)
  check("stepping on", bs.step(backwards = false) and bs.active == 2)
  check("and off the end", not bs.step(backwards = false))
  check("stepping back", bs.step(backwards = true) and bs.active == 1)
  bs.rewind(toLast = true)
  check("rewinding to the last", bs.active == 2)

# ---------------------------------------------------------------------------
echo "replace:"
# ---------------------------------------------------------------------------

block:
  var ed = buffer("abc abc abc")
  var bs = BufferSearch()
  bs.run(ed, "abc", {}, "d")
  var n = 0
  while bs.replaceActive(ed): inc n
  check("every match replaced", n == 3, $n)
  equals("by something shorter", ed.fullText.strip, "d d d")

block:
  var ed = buffer("abc abc")
  var bs = BufferSearch()
  bs.run(ed, "abc", {}, "longer")
  while bs.replaceActive(ed): discard
  equals("and by something longer", ed.fullText.strip, "longer longer")

block:
  var ed = buffer("keep abc keep")
  var bs = BufferSearch()
  bs.run(ed, "abc", {}, "")
  check("a replacement may be nothing at all", bs.replaceActive(ed))
  equals("which deletes the match", ed.fullText.strip, "keep  keep")

block:
  # One Ctrl+Z per replacement, not one per character of it.
  var ed = buffer("abc abc")
  var bs = BufferSearch()
  bs.run(ed, "abc", {}, "xy")
  discard bs.replaceActive(ed)
  discard bs.replaceActive(ed)
  equals("both replaced", ed.fullText.strip, "xy xy")
  ed.undo()
  equals("one undo takes back one replacement", ed.fullText.strip, "xy abc")
  ed.undo()
  equals("and the next takes back the other", ed.fullText.strip, "abc abc")

block:
  var ed = buffer("abc abc")
  var bs = BufferSearch()
  bs.run(ed, "abc", {}, "x")
  check("hits are fresh when they are found", not bs.stale(ed))
  discard bs.replaceActive(ed)
  check("a replace keeps them fresh", not bs.stale(ed))
  ed.gotoPos(ed.len)
  ed.insertText("!")
  check("any other edit does not", bs.stale(ed))
  check("and a stale search refuses to replace", not bs.replaceActive(ed))

block:
  # What a `replace` exchange does: yes consumes a hit, no steps over it, and
  # `done` is what says this buffer has nothing left to ask about.
  var ed = buffer("one two one two one")
  ed.gotoPos(0)
  var bs = BufferSearch()
  bs.run(ed, "one", {}, "1")
  check("three to answer for", bs.hits.len == 3)
  discard bs.replaceActive(ed)          # yes
  bs.skipActive()                       # no
  check("not done while one is left", not bs.done)
  discard bs.replaceActive(ed)          # yes
  check("done once the finger is past the end", bs.done)
  equals("the skipped one is untouched", ed.fullText.strip,
         "1 two one two 1")
  # `all` starts from the top again, which is what makes it include the ones
  # already passed over.
  bs.rewind(toLast = false)
  var n = 0
  while bs.replaceActive(ed): inc n
  check("the skipped hit is still in the list", n == 1, $n)
  equals("and 'all' gets it too", ed.fullText.strip, "1 two 1 two 1")

if failures == 0:
  echo "ALL PASS"
else:
  quit "FAILURE: " & $failures & " test(s)"
