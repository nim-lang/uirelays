## Tests for the clipboard history: what enters the list, what a row says, and
## what forgetting one does. Needs no window -- the clipboard itself is a relay
## like any other, so a test can be the one that holds the text.

import std/strutils
import uirelays/screen  # Font, which SynEdit only draws with
import uirelays/input   # clipboardRelays, which this test stands in for
import widgets/cliphistory

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

var systemClipboard = ""
proc heldText(): string {.nimcall.} = systemClipboard

proc copied(c: var ClipHistory; text: string) =
  ## What another application does, seen from here: the clipboard changes, and
  ## the next look picks it up.
  systemClipboard = text
  c.poll()

# ---------------------------------------------------------------------------
echo "cliphistory:"
# ---------------------------------------------------------------------------

block:
  var c = initClipHistory(Font(0))
  c.add "first"
  c.add "second"
  equals("the newest copy is row one", c.entry(1), "second")
  equals("and the one before it is row two", c.entry(2), "first")
  check("a row that does not exist is not an error",
        c.entry(0) == "" and c.entry(3) == "")
  c.add "first"
  check("copying something again does not keep two of it", c.len == 2)
  equals("it moves to the front instead", c.entry(1), "first")
  c.add ""
  check("an empty clipboard is not an entry", c.len == 2)

block:
  var c = initClipHistory(Font(0))
  for i in 1 .. MaxEntries + 5: c.add "clip" & $i
  check("the list stops growing", c.len == MaxEntries)
  equals("and it is the oldest that goes", c.entry(MaxEntries),
         "clip" & $6)

block:
  var c = initClipHistory(Font(0))
  c.add "keep me"
  c.add "by mistake"
  c.drop 1
  equals("forgetting a row leaves the rest", c.entry(1), "keep me")
  check("and there is one less of them", c.len == 1)
  c.drop 9
  check("forgetting a row that is not there does nothing", c.len == 1)

block:
  # The clipboard is read, not reported to: that is what makes a copy in
  # another application land here as well.
  clipboardRelays.getText = heldText
  var c = initClipHistory(Font(0))
  c.pollMs = 0                # a test has its own idea of when to look
  systemClipboard = "already there"
  c.poll()
  equals("what the clipboard held before we started is entry one",
         c.entry(1), "already there")
  c.poll()
  check("looking again at the same thing adds nothing", c.len == 1)
  c.copied "from another window"
  equals("a copy anywhere is a copy here", c.entry(1), "from another window")
  check("and the older one is still behind it", c.len == 2)
  systemClipboard = ""
  c.poll()
  check("a clipboard that says nothing takes nothing back", c.len == 2)

block:
  # A row is a label; the entry is the whole text.
  equals("one line is itself", rowLabel("addFloat"), "addFloat")
  equals("blanks are squeezed and the ends trimmed",
         rowLabel("  let a\t=   1  "), "let a = 1")
  equals("what did not fit is counted, not shown",
         rowLabel("proc foo =\n  discard\n  discard"),
         "proc foo =  (+2 lines)")
  equals("one line more says line, not lines",
         rowLabel("first\nsecond"), "first  (+1 line)")
  equals("a leading blank line is not the label",
         rowLabel("\n\n  the text"), "the text  (+2 lines)")
  equals("and whitespace alone says so", rowLabel("\t \n "), "(blank)  (+1 line)")
  let long = rowLabel("x".repeat(MaxRowLen + 20))
  check("a long line is cut", long.len == MaxRowLen + 3 and
        long[^3 .. ^1] == "...", long)

echo(if failures == 0: "  ok" else: "  " & $failures & " FAILURES")
quit(if failures == 0: 0 else: 1)
