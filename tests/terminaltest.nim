## The terminal is a SynEdit with a command line at the bottom of it: what a
## program printed is above that, protected from editing but not from being
## read. This is about the difference between the two -- where the caret is
## allowed to go, what brings it back, and what a key means in each place --
## and it runs through the same stub relays as `styletest`, so it needs no
## window and starts no program.
import uirelays/[screen, coords, input]
import std/[os, strutils]
import widgets/[synedit, terminal]

var clipboard = ""

fontRelays = FontRelays(
  openFont: proc (path: string; size: int; style: FontStyles;
                  metrics: var FontMetrics): Font =
    metrics = FontMetrics(ascent: 12, descent: 4, lineHeight: 16)
    Font(1),
  closeFont: proc (f: Font) = discard,
  getFontMetrics: proc (f: Font): FontMetrics =
    FontMetrics(ascent: 12, descent: 4, lineHeight: 16),
  measureText: proc (f: Font; text: string): TextExtent =
    TextExtent(w: text.len * 8, h: 16),
  drawText: proc (f: Font; x, y: int; text: string;
                  fg, bg: Color): TextExtent =
    TextExtent(w: text.len * 8, h: 16))

drawRelays = DrawRelays(
  fillRect: proc (r: Rect; color: Color) = discard,
  drawLine: proc (x1, y1, x2, y2: int; color: Color) = discard,
  drawPoint: proc (x, y: int; color: Color) = discard,
  loadImage: proc (path: string): Image = Image(0),
  freeImage: proc (img: Image) = discard,
  drawImage: proc (img: Image; src, dst: Rect) = discard)

clipboardRelays = ClipboardRelays(
  getText: proc (): string = clipboard,
  putText: proc (text: string) = clipboard = text)

var m: FontMetrics
let font = openFont("", 16, m)

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

const Area = rect(0, 0, 400, 200)

proc key(k: KeyCode; mods: set[Modifier] = {}): Event =
  Event(kind: KeyDownEvent, key: k, mods: mods)

proc typed(c: char): Event =
  result = Event(kind: TextInputEvent)
  result.text[0] = c

proc newTerm(): Terminal =
  ## A terminal that has printed something and is waiting at its prompt.
  result = createTerminal(font)
  result.ed.appendOutput("total 3\Lone.nim\Ltwo.nim\L")
  result.insertPrompt()

proc frame(t: var Terminal; e = default(Event)) =
  discard t.draw(e, Area, focused = true)

proc typeText(t: var Terminal; text: string) =
  for c in text: t.frame(typed(c))

proc commandLine(t: Terminal): string =
  ## What has been typed after the last prompt.
  result = ""
  for i in t.ed.readOnly + 1 ..< t.ed.len: result.add t.ed[i]

proc allText(t: Terminal): string =
  result = ""
  for i in 0 ..< t.ed.len: result.add t.ed[i]

proc offsetOf(t: Terminal; part: string): int =
  ## Where `part` starts in the buffer. The prompt carries a path and a branch
  ## name, so nothing in this test may count characters from the top.
  result = t.allText.find(part)
  doAssert result >= 0, part & " is not in the buffer"

proc runBuiltin(t: var Terminal; cmd: string) =
  ## A command the terminal answers itself, so no program is started and the
  ## prompt comes back within the call.
  t.typeText(cmd)
  t.frame(key(KeyEnter))

echo "terminal:"

block: # the caret goes into what was printed, and stays there
  var t = newTerm()
  t.frame()
  let at = t.offsetOf("one.nim")
  t.ed.gotoPos(at)
  t.frame()
  check("the caret stays where it was put in the output", t.ed.cursor == at,
        $t.ed.cursor & " of " & $at)
  t.frame(key(KeyRight))
  check("and moves through it like any other text", t.ed.cursor == at + 1,
        $t.ed.cursor)
  t.frame(key(KeyRight, {ShiftPressed}))
  t.frame(key(KeyRight, {ShiftPressed}))
  check("and text up there can be selected", t.ed.getSelectedText() == "ne",
        "'" & t.ed.getSelectedText() & "'")

block: # but a key that edits belongs to the command line
  var t = newTerm()
  t.typeText("ls")
  t.ed.gotoPos(t.offsetOf("one.nim"))
  t.typeText(" -l")
  check("typing goes to the command line wherever the caret was",
        t.commandLine == "ls -l", "'" & t.commandLine & "'")
  check("and the caret is there afterwards", t.ed.cursor == t.ed.len,
        $t.ed.cursor & " of " & $t.ed.len)

block: # Up is the history on the command line and a caret key above it
  var t = newTerm()
  t.runBuiltin("cd .")
  t.frame(key(KeyUp))
  check("Up on the command line brings the last command back",
        t.commandLine == "cd .", "'" & t.commandLine & "'")
  let line = t.ed.currentLine
  t.ed.gotoPos(t.offsetOf("one.nim"))
  t.frame(key(KeyUp))
  check("Up in the output moves the caret instead",
        t.ed.currentLine < line and t.commandLine == "cd .",
        $t.ed.currentLine & " '" & t.commandLine & "'")

block: # the history must not spin when the caret is inside the command
  var t = newTerm()
  t.runBuiltin("cd .")
  t.typeText("xyz")
  t.ed.gotoPos(t.ed.len - 2)    # in the middle of what was typed
  t.frame(key(KeyUp))
  check("the history replaces a command the caret was standing in",
        t.commandLine == "cd .", "'" & t.commandLine & "'")

block: # output does not drag a reader away from what they are reading
  var t = newTerm()
  t.frame()
  let at = t.offsetOf("one.nim")
  t.ed.gotoPos(at)
  t.ed.appendOutput("more output\L")
  check("printing leaves a caret that was left in the output alone",
        t.ed.cursor == at, $t.ed.cursor & " of " & $at)
  t.ed.gotoPos(t.ed.len)
  let atEnd = t.ed.len
  t.ed.appendOutput("and more\L")
  check("but a caret at the end follows the output down",
        t.ed.cursor > atEnd, $t.ed.cursor)

block: # Ctrl+C is a copy when there is something to copy
  var t = newTerm()
  t.processRunning = true
  t.ed.gotoPos(t.offsetOf("two.nim"))
  for i in 1..3: t.frame(key(KeyRight, {ShiftPressed}))
  clipboard = ""
  t.frame(key(KeyC, {CtrlPressed}))
  check("Ctrl+C copies the selection", clipboard == "two",
        "'" & clipboard & "'")
  t.ed.deselect()
  t.frame(key(KeyC, {CtrlPressed}))
  check("and with nothing selected it is still the break", t.processRunning)

block: # the prompt follows the branch, not only the directory
  # A checkout is a rewritten `.git/HEAD`, and that file is all the prompt
  # watches -- so this needs no repository and runs no `git`, only the file.
  # The two names differ in length as well as in content, because a file
  # system that dates a file by the second is still allowed to date both
  # writes the same.
  let repo = getTempDir() / "uirelays-branch-test"
  removeDir repo
  createDir repo / ".git"
  writeFile(repo / ".git" / "HEAD", "ref: refs/heads/master\L")
  var t = createTerminal(font)
  t.cwd = repo
  t.insertPrompt()
  check("the prompt shows the branch that is checked out",
        t.allText.contains("[master]"), t.allText)
  writeFile(repo / ".git" / "HEAD", "ref: refs/heads/topic\L")
  t.insertPrompt()
  check("and follows a checkout nobody told it about",
        t.allText.contains("[topic]"), t.allText)
  writeFile(repo / ".git" / "HEAD", "0123456789abcdef0123456789abcdef01234567\L")
  t.insertPrompt()
  check("a detached HEAD reads as its short hash",
        t.allText.contains("[0123456]"), t.allText)
  removeDir repo

block: # what marks the cached branch stale
  check("`cd` is seen as a word", mentionsCd("mkdir x && cd x"))
  check("and not inside one", not mentionsCd("abcd") and not mentionsCd("cdrom"))
  check("a `git` is seen the same way", mentionsWord("git init", "git"))
  check("and `digit` is not one", not mentionsWord("echo digital", "git"))

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
