## Tests for the console highlighter -- what a terminal's output is colored by.
## The classes are the output of a highlighter; the theme only turns them into
## colors, so this needs no window and no font.

import uirelays/screen        # Font, which SynEdit only draws with
import widgets/[synedit, theme]

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

proc classesOf(text: string): seq[TokenClass] =
  ## The class of every character, after the whole buffer has been walked.
  var ed = createSynEdit(Font(0))
  ed.lang = langConsole   # before the text: `setText` highlights what it took
  ed.setText(text)
  result = @[]
  for i in 0 ..< ed.len: result.add ed.tokenClassAt(i)

proc appendedClasses(chunks: openArray[string]): seq[TokenClass] =
  ## The same, for text that arrives the way a program's output does: through
  ## `appendOutput`, in chunks that fall wherever the pipe happened to break.
  var ed = createSynEdit(Font(0))
  ed.lang = langConsole
  for c in chunks: ed.appendOutput(c)
  result = @[]
  for i in 0 ..< ed.len: result.add ed.tokenClassAt(i)

proc allOf(cls: seq[TokenClass]; a, b: int): string =
  ## One class for the range, or "mixed".
  result = $cls[a]
  for i in a .. b:
    if cls[i] != cls[a]: return "mixed"

proc classOf(text, part: string): string =
  ## The class of `part` inside `text`, or "mixed" if it is not all one class
  ## -- which is itself the answer to "does this get colored as one thing".
  let cls = classesOf(text)
  var at = -1
  for i in 0 .. text.len - part.len:
    if text[i ..< i + part.len] == part: at = i; break
  if at < 0: return "not found"
  let first = cls[at]
  for i in at ..< at + part.len:
    if cls[i] != first: return "mixed"
  result = $first

# ---------------------------------------------------------------------------
echo "console highlighting:"
# ---------------------------------------------------------------------------

block: # a diff, which is what this is mostly read on
  const diff = """diff --git a/x.nim b/x.nim
@@ -1,3 +1,3 @@
 unchanged
-was this
+is that now
"""
  equals("a removed line is red, all of it", classOf(diff, "-was this"), "Red")
  equals("an added line is green", classOf(diff, "+is that now"), "Green")
  equals("a context line is not colored", classOf(diff, "unchanged"),
         "Identifier")
  equals("the hunk header is a directive", classOf(diff, "@@ -1,3 +1,3 @@"),
         "Directive")
  # The dashes of `--git` are not at the start of a line, so they colour
  # nothing: `diff --git ...` is a header, not a removal.
  equals("a dash inside a line is just a dash", classOf(diff, "--"), "None")

block: # compiler output
  equals("an error says so in red",
         classOf("x.nim(3, 1) Error: undeclared 'y'", "Error:"), "Red")
  equals("a warning in yellow",
         classOf("x.nim(3, 1) Warning: unused [XDeclared]", "Warning:"),
         "Yellow")
  equals("a hint in green", classOf("x.nim(1, 1) Hint: used [Conf]", "Hint:"),
         "Green")
  equals("the tag at the end is a rule",
         classOf("x.nim(1, 1) Hint: used [Conf]", "[Conf]"), "Rule")
  equals("a path stays one token", classOf("cat src/widgets/synedit.nim", "src/widgets/synedit.nim"),
         "Identifier")

block: # what must not happen
  equals("a bracket that closes nothing is left alone",
         classOf("ls [abc", "[abc"), "mixed")
  # A bracketed word after a space is a tag wherever it stands, and the prompt
  # is written into the same buffer as the output -- so the branch in it reads
  # as one. Harmless, and the alternative is a rule that knows about prompts.
  equals("a bracketed word is a tag wherever it is",
         classOf("/home/x [branch]> ls", "[branch]"), "Rule")
  # A name with anything but letters in it is not one, which is what keeps
  # most branch names out.
  equals("a bracket that holds more than a word is not",
         classOf("/home/x [my-branch]> ls", "[my-branch]"), "mixed")

block: # output does not arrive in one piece, and never through setText
  # One chunk, many lines: highlighting only the last line of it -- which is
  # the empty one after the final newline -- leaves a diff colorless.
  let cls = appendedClasses(["@@ -1,3 +1,3 @@\n-was this\n+is that now\n"])
  equals("a hunk header in appended output", allOf(cls, 0, 14), "Directive")
  equals("a removed line in appended output", allOf(cls, 16, 24), "Red")
  equals("an added line in appended output", allOf(cls, 26, 36), "Green")

block: # a chunk boundary is not a line boundary
  # The pipe breaks where it likes, and the prompt is appended on its own.
  let cls = appendedClasses(["/tmp>", " git diff\n", "-was ", "this\n"])
  let start = "/tmp> git diff\n".len
  equals("a line split across two chunks is still one line",
         allOf(cls, start, start + "-was this".len - 1), "Red")

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
