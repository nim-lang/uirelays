## Tests for the word index: what counts as a word, how a prefix is matched,
## and that a word list survives being written and read back. Needs no window
## -- the buffer walk is the only part that touches SynEdit, and a SynEdit
## needs no font until something draws it.

import std/[os, strutils]
import uirelays/screen  # Font, which SynEdit only draws with
import widgets/[synedit, wordindex]

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc scanned(text: string): string =
  var bag = WordBag()
  scanWords(text, bag)
  result = bag.words.join(" ")

# ---------------------------------------------------------------------------
echo "wordindex:"
# ---------------------------------------------------------------------------

block:
  equals("plain words", scanned("proc addFloat(x: Foo)"),
         "proc addFloat Foo")
  equals("single letters are not worth offering", scanned("var i = x"),
         "var")
  equals("a number is not a word", scanned("let a = 0xffff + 1e9"),
         "let")
  equals("but a name may end in digits", scanned("uint8 utf8"),
         "uint8 utf8")
  equals("underscores hold a word together", scanned("do_it_now"), "do_it_now")
  equals("each word once", scanned("add add add sub"), "add sub")

block:
  # The cursor sits inside the second `addF`; a half-typed name must not be
  # offered as its own completion.
  var bag = WordBag()
  scanWords("addFloat\naddF", bag, skipAround = 13)
  equals("the word under the cursor is left out", bag.words.join(" "),
         "addFloat")

block:
  check("exact prefix", stylePrefix("addFloat", "addF"))
  check("case after the first letter does not matter",
        stylePrefix("addFloat", "addf"))
  check("underscores do not matter", stylePrefix("add_float", "addF"))
  check("on either side", stylePrefix("addFloat", "add_f"))
  check("the first letter does matter", not stylePrefix("addFloat", "Add"))
  check("a prefix is not a suffix", not stylePrefix("addFloat", "float"))
  check("nothing matches everything", stylePrefix("addFloat", ""))

block:
  var idx = WordIndex()
  idx.addSet WordSet(name: "std", words: @["addFloat", "add_int", "Address",
                                           "readAll", "unrelated"])
  let m = idx.complete("add")
  equals("what starts with it, then what merely contains it",
         m.join(" "), "addFloat add_int Address")
  check("a listing is capped", idx.complete("", limit = 2).len == 2)
  let v = idx.version
  idx.addSet WordSet(name: "other", words: @["addFloat"])
  check("a word already known does not make the listing stale",
        idx.version == v)
  idx.addSet WordSet(name: "third", words: @["addQuux"])
  check("but a new one does", idx.version > v)

block:
  var idx = WordIndex()
  idx.addSet WordSet(name: "a", words: @["shared", "onlyA"])
  idx.addSet WordSet(name: "b", words: @["shared", "onlyB"])
  check("dropping a set forgets its words", idx.dropSet("a"))
  equals("but keeps what another set also had",
         idx.complete("").join(" "), "onlyB shared")
  check("dropping what is not there says so", not idx.dropSet("a"))

block:
  var idx = WordIndex()
  idx.addSet WordSet(name: "p", words: @["first"])
  idx.addSet WordSet(name: "p", words: @["second"])
  equals("indexing the same path again replaces its words",
         idx.complete("").join(" "), "second")

block:
  # Round trip, including the names NIF cannot spell as a bare ident.
  let src = WordSet(name: "/tmp/some dir", words: @["addFloat", "[]=",
                                                   "=destroy", "abs"])
  var back = WordSet()
  let err = parseWordSet(src.toNif, back)
  equals("the file parses", err, "")
  equals("the source came through", back.name, "/tmp/some dir")
  equals("sorted, and every word intact", back.words.join(" "),
         "=destroy []= abs addFloat")
  check("a long list is wrapped, not one endless line",
        src.toNif.splitLines.len >= 3)

block:
  var back = WordSet()
  check("a section a later version adds is stepped over",
        parseWordSet("(words (lang nim) (w abs) (kinds (proc abs)))",
                     back).len == 0)
  equals("and the words still arrive", back.words.join(" "), "abs")
  check("a broken list is reported, not raised",
        parseWordSet("(nonsense", back).len > 0)
  check("so is a truncated one", parseWordSet("(words (w abs", back).len > 0)

block:
  # The buffer walk: incremental, and it stops at the slice size.
  var ed = createSynEdit(Font(0))
  var text = ""
  for i in 1 .. 50: text.add "line" & $i & " common\n"
  ed.setText(text)
  ed.gotoPos(ed.len)   # or the word the cursor sits in would be left out
  var idx = WordIndex()
  var st = BufferIndexer()
  check("a slice does not finish a long buffer",
        idx.indexSlice(ed, st, lines = 10))
  var guard = 0
  while idx.indexSlice(ed, st, lines = 10) and guard < 100: inc guard
  check("but it gets there", guard < 100)
  check("everything is in", idx.complete("line").len == 50)
  check("nothing more to do", not idx.indexSlice(ed, st))
  # An edit invalidates the walk without any bookkeeping at the call site.
  ed.gotoPos(ed.len)
  ed.insertText("\nfreshWord\n")
  guard = 0
  while idx.indexSlice(ed, st) and guard < 100: inc guard
  equals("an edit is picked up", idx.complete("fresh").join(" "), "freshWord")

block:
  # The whole point, end to end: type a prefix, take a completion, undo it.
  var ed = createSynEdit(Font(0))
  ed.setText("addFloat\nadd")
  ed.gotoPos(ed.len)
  equals("the prefix is what the cursor sits behind", ed.getWordPrefix, "add")
  ed.replaceWordPrefix("addFloat")
  equals("accepting swaps the word", ed.fullText, "addFloat\naddFloat")
  ed.undo()
  equals("and one undo takes it back", ed.fullText, "addFloat\nadd")
  ed.redo()
  equals("redo puts it back", ed.fullText, "addFloat\naddFloat")

block:
  # A completion in the middle of a line keeps what follows it.
  var ed = createSynEdit(Font(0))
  ed.setText("x = ad + 1")
  ed.gotoLine(1, 6)
  ed.replaceWordPrefix("addFloat")
  equals("the rest of the line stays put", ed.fullText, "x = addFloat + 1")

block:
  # Indexing a directory: this very test directory, which is full of Nim.
  var job = startIndexJob(currentSourcePath().parentDir)
  check("there is something to do", job.active)
  var guard = 0
  while stepIndexJob(job, files = 2) and guard < 500: inc guard
  check("the job ends", guard < 500)
  let ws = doneIndexJob(job)
  check("and it found the words in this file",
        "stylePrefix" in ws.words and "parseWordSet" in ws.words,
        $ws.words.len & " words")

if failures > 0: quit "FAILURE: " & $failures & " test(s) failed"
echo "  ok"
