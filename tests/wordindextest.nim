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
  # Round trip, including the names that are not identifiers at all.
  let src = WordSet(name: "/tmp/some dir", words: @["addFloat", "[]=",
                                                   "=destroy", "abs"])
  let back = parseWordSet(src.toText)
  equals("the source came through", back.name, "/tmp/some dir")
  equals("sorted, and every word intact", back.words.join(" "),
         "=destroy []= abs addFloat")
  equals("the file is the source, then one word per line", src.toText,
         "/tmp/some dir\n=destroy\n[]=\nabs\naddFloat\n")

block:
  # A list edited by hand: blank lines, indentation, a trailing newline.
  let back = parseWordSet("/some/where\n\n  abs\nadd  \n\n")
  equals("the first line is where it came from", back.name, "/some/where")
  equals("and the rest are words", back.words.join(" "), "abs add")
  let empty = parseWordSet("")
  equals("an empty file is an empty set", $empty.words.len, "0")
  equals("the first line is the source even when it reads like a word",
         parseWordSet("abs\nadd").words.join(" "), "add")

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
  # `gotoLine` has to reach the last line: it is how the tab list and the
  # history panel act on a row, and the bottom row is a row like any other.
  var ed = createSynEdit(Font(0))
  ed.setText("aa\nbb\ncc")
  ed.gotoLine(3, 0)
  equals("the last line is reachable", $ed.currentLine, "2")
  ed.deleteLine()
  equals("so acting on it acts on it", ed.fullText, "aa\nbb")
  ed.gotoLine(99, 0)
  equals("past the end is the last line", $ed.currentLine, "1")

block:
  # The multi-token prefix: what a suggestion longer than a word completes.
  var ed = createSynEdit(Font(0))
  ed.setText("x = 1\nresult.add x")
  ed.gotoPos(ed.len)
  equals("one token is the word", ed.getSpanPrefix(1).text, "x")
  equals("two reach over the space", ed.getSpanPrefix(2).text, "add x")
  equals("punctuation is a token of its own", ed.getSpanPrefix(3).text,
         ".add x")
  equals("and four take the line", ed.getSpanPrefix(4).text, "result.add x")
  equals("asking for more than there is stops at the line start",
         ed.getSpanPrefix(99).text, "result.add x")
  check("the offset is where the text begins",
        ed.getSpanPrefix(99).start == ed.len - "result.add x".len)
  ed.gotoLine(2, 7)
  equals("a token can be the punctuation itself", ed.getSpanPrefix(1).text, ".")
  ed.gotoPos(ed.len)
  ed.insertText(" ")
  equals("a trailing space comes along", ed.getSpanPrefix(1).text, "x ")
  ed.gotoLine(1, 0)
  equals("at the start of a line there is nothing behind the caret",
         ed.getSpanPrefix(3).text, "")

block:
  # Replacing a span is one undo step, however many tokens it spans.
  var ed = createSynEdit(Font(0))
  ed.setText("case x")
  ed.gotoPos(ed.len)
  let span = ed.getSpanPrefix(2)
  ed.replaceSpan(span.start, "case typ.kind")
  equals("the whole span is swapped", ed.fullText, "case typ.kind")
  ed.undo()
  equals("and one undo takes all of it back", ed.fullText, "case x")

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
