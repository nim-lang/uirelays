## Tests for `track`: the project file a `.nim` belongs to, the records the
## compilers answer with, and the `(track ...)` that says which compiler to
## ask. No compiler is run here -- what is tested is everything around one.

import std/[os, strutils]
import uirelays/screen  # Font, which SynEdit only draws with
import widgets/[track, config, synedit]

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc `$`(h: TrackHit): string =
  (if h.isDef: "def " else: "use ") & h.name & " " & h.path.extractFilename &
  ":" & $h.line & ":" & $h.col

proc list(hits: seq[TrackHit]): string =
  for i, h in hits:
    if i > 0: result.add " | "
    result.add $h

# ---------------------------------------------------------------------------
echo "reading what a compiler answered:"
# ---------------------------------------------------------------------------

const sep = "\t"

block:
  # What `nim track --defusages:` writes: section, symbol kind, name, forth,
  # path, line, column, doc, quality. `nim` prints its progress to the other
  # stream, and a terminal that merges the two can leave a run of dots in front
  # of the first record.
  let out1 = [
    "..........def" & sep & "skUnknown" & sep & "greet" & sep & sep &
      "/p/helper.nim" & sep & "1" & sep & "5" & sep & sep & "100",
    "use" & sep & "skUnknown" & sep & "greet" & sep & sep &
      "/p/helper.nim" & sep & "1" & sep & "5" & sep & sep & "100",
    "use" & sep & "skUnknown" & sep & "greet" & sep & sep &
      "/p/main.nim" & sep & "6" & sep & "5" & sep & sep & "100",
    "Hint: 4 lines; 0.5s [SuccessX]"].join("\n")
  let hits = parseHits(out1, "/p")
  equals("nim: three records, the leading dots and the hint ignored",
         hits.list,
         "def greet helper.nim:1:5 | use greet helper.nim:1:5 | " &
         "use greet main.nim:6:5")

block:
  # What nimony's `--def` / `--usages` write: section, an empty kind, the
  # mangled symbol, two empty fields, path, line, column. One field fewer in
  # front and two fewer behind, which is why the file is looked for by shape
  # rather than counted to.
  let out2 = [
    "def" & sep & sep & "greet.0.hlp" & sep & sep & sep &
      "/p/helper.nim" & sep & "1" & sep & "5",
    "use" & sep & sep & "greet.0.hlp" & sep & sep & sep &
      "main.nim" & sep & "6" & sep & "5"].join("\n")
  let hits = parseHits(out2, "/p")
  equals("nimony: the mangled name is cut back to the identifier",
         hits.list, "def greet helper.nim:1:5 | use greet main.nim:6:5")
  check("nimony: a relative path is resolved against the project",
        hits[1].path == "/p" / "main.nim", hits[1].path)

block:
  check("a line that is not a record is not one",
        parseHits("Hint: operation successful [SuccessX]\nusages: 3\n",
                  "/p").len == 0)
  check("a record needs its two numbers",
        parseHits("def" & sep & "skUnknown" & sep & "x" & sep & sep &
                  "/p/a.nim" & sep & "one" & sep & "two", "/p").len == 0)

# ---------------------------------------------------------------------------
echo "tidying the answer:"
# ---------------------------------------------------------------------------

block:
  # A forward declaration is two declarations, so even "go to declaration" has
  # two answers -- which is the reason the editor offers a list at all.
  let raw = @[
    TrackHit(isDef: false, name: "twice", path: "/p/main.nim", line: 7, col: 5),
    TrackHit(isDef: true, name: "twice", path: "/p/main.nim", line: 4, col: 5),
    TrackHit(isDef: false, name: "twice", path: "/p/main.nim", line: 4, col: 5),
    TrackHit(isDef: true, name: "twice", path: "/p/main.nim", line: 3, col: 5),
    TrackHit(isDef: false, name: "twice", path: "/p/main.nim", line: 3, col: 5)]
  equals("declarations first, then usages, each in the order of the text",
         raw.tidy.list,
         "def twice main.nim:3:5 | def twice main.nim:4:5 | " &
         "use twice main.nim:7:5")

block:
  let raw = @[
    TrackHit(isDef: false, name: "a", path: "/p/b.nim", line: 2, col: 1),
    TrackHit(isDef: false, name: "a", path: "/p/a.nim", line: 9, col: 1),
    TrackHit(isDef: false, name: "a", path: "/p/a.nim", line: 2, col: 4),
    TrackHit(isDef: false, name: "a", path: "/p/a.nim", line: 2, col: 1)]
  equals("by file, then line, then column", raw.tidy.list,
         "use a a.nim:2:1 | use a a.nim:2:4 | use a a.nim:9:1 | use a b.nim:2:1")

# ---------------------------------------------------------------------------
echo "finding the project file:"
# ---------------------------------------------------------------------------

let root = getTempDir() / "focim-tracktest"
removeDir root
createDir root / "pkg" / "src" / "deep"
writeFile(root / "pkg" / "pkg.nimble", "# a package\n")
writeFile(root / "pkg" / "src" / "pkg.nim", "import deep/thing\n")
writeFile(root / "pkg" / "src" / "deep" / "thing.nim", "proc thing* = discard\n")

equals("a module below the source directory finds the package's main module",
       findProjectFile(root / "pkg" / "src" / "deep" / "thing.nim"),
       root / "pkg" / "src" / "pkg.nim")

createDir root / "solo"
writeFile(root / "solo" / "script.nim", "echo 1\n")
equals("a file that belongs to no project finds nothing",
       findProjectFile(root / "solo" / "script.nim"), "")

createDir root / "cfged"
writeFile(root / "cfged" / "app.nim", "echo 1\n")
writeFile(root / "cfged" / "app.nim.cfg", "--path:\".\"\n")
writeFile(root / "cfged" / "helper.nim", "proc h* = discard\n")
equals("a .cfg beside a .nim of the same name names the project",
       findProjectFile(root / "cfged" / "helper.nim"),
       root / "cfged" / "app.nim")

createDir root / "two"
writeFile(root / "two" / "a.nimble", "# one\n")
writeFile(root / "two" / "b.nimble", "# and another\n")
writeFile(root / "two" / "a.nim", "echo 1\n")
writeFile(root / "two" / "b.nim", "echo 2\n")
equals("two .nimble files in one directory give up rather than guess",
       findProjectFile(root / "two" / "a.nim"), "")
removeDir root

# ---------------------------------------------------------------------------
echo "positions, the way a compiler states them:"
# ---------------------------------------------------------------------------

proc buffer(text: string): SynEdit =
  result = createSynEdit(Font(0))
  result.lang = langNim
  result.setText(text)

block:
  let ed = buffer("proc greet*(name: string): string =\n  result = name\n")
  let (word, a, b) = ed.wordAt(7)
  equals("the name a click landed in, however far into it", word, "greet")
  check("with the offsets of its ends", a == 5 and b == 9, $a & ".." & $b)
  let (line, col) = ed.lineAndByteCol(a)
  check("stated as a 1-based line and a 0-based column",
        line == 1 and col == 5, $line & ":" & $col)
  check("a click between names is not on one", ed.wordAt(4).word.len == 0)
  check("nor is one past the end of the text",
        ed.wordAt(ed.len).word.len == 0)

block:
  # `0xffff` is not a name, and neither is the `1` of a `x1` clicked on its
  # own -- the walk to the front of the run has already covered the latter.
  let ed = buffer("let x1 = 0xffff\n")
  equals("a run that starts with a digit is not a name",
         ed.wordAt(11).word, "")
  equals("a digit inside a name still belongs to it", ed.wordAt(5).word, "x1")

block:
  # A compiler counts bytes into the line; SynEdit moves by characters. The two
  # part company behind a multi-byte rune, and it is the compiler that has to
  # be believed.
  var ed = buffer("echo \"f\xc3\xb6\xc3\xb6\", value\n")
  ed.gotoLineBytes(1, 14)
  equals("a byte column lands where the compiler meant it to",
         ed.wordAt(ed.cursor).word, "value")
  let (line, col) = ed.lineAndByteCol(ed.cursor)
  check("and reading it back gives the same position",
        line == 1 and col == 14, $line & ":" & $col)

# ---------------------------------------------------------------------------
echo "(track ...) in the config:"
# ---------------------------------------------------------------------------

block:
  let c = parseConfig("""
(config
  (layout (editor))
  (track
    (compiler "nimony")
    (exe "/opt/nimony/bin/nimony")))
""")
  check("parses", c.error.len == 0, c.error)
  equals("the compiler", $c.track.compiler, "nimony")
  equals("the binary", c.track.exeName, "/opt/nimony/bin/nimony")

block:
  let c = parseConfig("(config (layout (editor)) (track (compiler \"none\")))")
  check("parses", c.error.len == 0, c.error)
  equals("tracking can be turned off", $c.track.compiler, "none")

block:
  let c = parseConfig("(config (layout (editor)))")
  check("parses", c.error.len == 0, c.error)
  equals("a config that says nothing about it gets nim", $c.track.compiler,
         "nim")
  equals("run by its own name", c.track.exeName, "nim")

block:
  let c = parseConfig("(config (layout (editor)) (track (compiler \"gcc\")))")
  check("a compiler nobody here can drive is refused", c.error.len > 0)
  check("and the message says which ones there are",
        "\"nimony\"" in c.error, c.error)
  equals("and nothing of it is kept", $c.track.compiler, "nim")

block:
  let c = parseConfig("(config (layout (editor)) (track (verbose \"yes\")))")
  check("an unknown track field is refused", c.error.len > 0)
  check("and it says what does belong there", "(compiler" in c.error, c.error)

block:
  let c = parseConfig(
    "(config (layout (editor)) (track (compiler \"nim\")) (track (exe \"x\")))")
  check("only one (track ...) per config", c.error.len > 0)

if failures > 0:
  quit "FAILURE: " & $failures & " test(s) failed"
echo "all tracking tests passed"
