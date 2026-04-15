##[
Design Notes:

Everything is text. The core widget is **SynEdit** -- a syntax-aware text
editor ported from NimEdit. Labels, status bars, and terminals are all
SynEdit instances with different configurations:

- **Editor**: Full editing with syntax highlighting, undo, line numbers
- **Label / status bar**: Read-only SynEdit via `setLabel()`
- **Terminal**: SynEdit wrapped with command execution, history, tab completion
- **Cmd+click** (macOS) / **Ctrl+click** (other): clickable text -- the app
  decides what happens (open file, go to definition, navigate directory)
]##

import std/[tables, os]
from std/cmdline import paramCount, paramStr
import uirelays
import uirelays/layout
import widgets/[synedit, terminal]

const appLayout = parseLayout("""
| title, 1 line                                        |
| files, 120px | editor, *       | terminal, *         |
| status, 1 line                                       |
""")

const sampleCode = """
import strutils, os

type
  Person = object
    name: string
    age: int

proc greet(p: Person) =
  echo "Hello, " & p.name & "! You are " & $p.age & " years old."

proc main() =
  let people = @[
    Person(name: "Alice", age: 30),
    Person(name: "Bob", age: 25),
  ]
  for p in people:
    greet(p)

when isMainModule:
  main()
"""

const
  PathChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '.', '/', '\\',
               '-', '~', '\128'..'\255'}

proc extractPath(s: SynEdit; pos: int): tuple[path: string, a, b: int] =
  ## Extract the file path around buffer position `pos`.
  if pos < 0 or pos >= s.len or s[pos] notin PathChars:
    return ("", -1, -1)
  var first = pos
  var last = pos
  while first > 0 and s[first - 1] in PathChars: dec first
  while last + 1 < s.len and s[last + 1] in PathChars: inc last
  var path = ""
  for i in first .. last: path.add s[i]
  result = (path, first, last)

proc extractFilePosition(s: SynEdit; pos: int):
    tuple[file: string, line, col, a, b: int] =
  ## Parse "file.nim(10, 3)" or "file.nim:10:3:" starting from `pos`.
  result = ("", -1, -1, -1, -1)
  let (path, a, b) = s.extractPath(pos)
  if path.len == 0: return
  var i = b + 1
  if i >= s.len: return (path, -1, -1, a, b)
  var ln, fc: int
  template parseNum(num: var int) =
    while i < s.len and s[i] in {'0'..'9'}:
      num = num * 10 + (ord(s[i]) - ord('0'))
      inc i
  if s[i] == '(' and i + 1 < s.len and s[i + 1] in {'0'..'9'}:
    inc i
    parseNum(ln)
    if i < s.len and s[i] == ',':
      inc i
      while i < s.len and s[i] == ' ': inc i
      parseNum(fc)
    result = (path, ln, fc, a, i - 1)
  elif s[i] == ':' and i + 1 < s.len and s[i + 1] in {'0'..'9'}:
    inc i
    parseNum(ln)
    if i < s.len and s[i] == ':':
      inc i
      parseNum(fc)
    result = (path, ln, fc, a, i - 1)
  else:
    result = (path, -1, -1, a, b)

type
  BufferEntry = object
    ed: SynEdit
    path: string        ## "" for scratch buffers

proc openFile(buffers: var seq[BufferEntry]; font: Font;
              path: string; line, col: int): int =
  ## Open a file or switch to it if already open. Returns the buffer index.
  for i, b in buffers:
    if b.path == path:
      if line >= 0: buffers[i].ed.gotoLine(line, max(col, 0))
      return i
  var ed = createSynEdit(font)
  ed.showLineNumbers = true
  ed.lang = fileExtToLanguage(path.splitFile.ext)
  ed.loadFromFile(path)
  if line >= 0: ed.gotoLine(line, max(col, 0))
  buffers.add BufferEntry(ed: ed, path: path)
  result = buffers.high

proc updateFilesPanel(files: var SynEdit; buffers: seq[BufferEntry];
                      current: int) =
  var text = ""
  for i, b in buffers:
    let name = if b.path.len > 0: b.path.extractFilename else: "[scratch]"
    let modified = if b.ed.changed: " *" else: ""
    let marker = if i == current: " <" else: ""
    text.add name & modified & marker
    if i < buffers.high: text.add "\n"
  files.setLabel(text)

proc handleTermCtrlClick(buf: SynEdit; pos: int;
                         buffers: var seq[BufferEntry]; current: var int;
                         font: Font; term: var Terminal;
                         focus: var string) =
  let (file, ln, fc, a, b) = buf.extractFilePosition(pos)
  if file.len == 0: return
  let path = if isAbsolute(file): file else: os.getCurrentDir() / file
  term.ed.underline(a, b)
  if dirExists(path):
    os.setCurrentDir(path)
    setWindowTitle("SynEdit Demo - " & path)
    term.ed.appendOutput("\L")
    term.insertPrompt()
    var lsCmd = "ls"
    discard term.runCommand(lsCmd)
  elif fileExists(path):
    current = buffers.openFile(font, path, ln, fc)
    setWindowTitle("SynEdit - " & path.extractFilename)
    focus = "editor"

proc updateStatus(status: var Terminal; ed: SynEdit; path: string) =
  let name = if path.len > 0: path.extractFilename else: "[scratch]"
  let info = name & "  Ln " & $(ed.currentLine + 1) &
             ", Col " & $(ed.currentCol + 1) &
             (if ed.changed: "  *" else: "") & " > "
  status.ed.clear()
  status.ed.lang = langConsole
  status.ed.appendOutput(info)

proc tryOpenFile(arg: string; buffers: var seq[BufferEntry];
                 current: var int; font: Font; focus: var string) =
  let path = if isAbsolute(arg): arg else: os.getCurrentDir() / arg
  if fileExists(path):
    current = buffers.openFile(font, path, -1, -1)
    setWindowTitle("SynEdit - " & path.extractFilename)
    focus = "editor"
  elif dirExists(path):
    os.setCurrentDir(path)
    setWindowTitle("SynEdit Demo - " & path)


proc main =
  let screen = createWindow(1100, 700)
  var width = screen.width
  var height = screen.height

  var fm: FontMetrics
  let font = openFont("", 16, fm)
  setWindowTitle("SynEdit Demo")

  var title = createSynEdit(font)
  var files = createSynEdit(font)
  var term = createTerminal(font)
  var status = createTerminal(font)

  title.setLabel("SynEdit Demo")

  # Buffer list
  var buffers: seq[BufferEntry]
  var current = 0
  if paramCount() >= 1:
    current = buffers.openFile(font, paramStr(1), -1, -1)
  else:
    var ed = createSynEdit(font)
    ed.lang = langNim
    ed.showLineNumbers = true
    ed.setText(sampleCode)
    buffers.add BufferEntry(ed: ed, path: "")

  var focus = "editor"

  var running = true
  while running:
    let cells = appLayout.resolve(width, height, fm.lineHeight, gap = 2)

    # Fill background -- gaps between cells show this color as borders
    fillRect(rect(0, 0, width, height), color(200, 200, 200))

    var e = default Event
    discard waitEvent(e, 500, {WantTextInput})
    case e.kind
    of QuitEvent, WindowCloseEvent:
      running = false
    of WindowResizeEvent:
      width = e.x
      height = e.y
    of MouseDownEvent:
      let hit = cells.hitTest(e.x, e.y)
      if hit.name.len > 0:
        focus = hit.name
    of KeyDownEvent:
      let cmd = CtrlPressed in e.mods or GuiPressed in e.mods
      if cmd and e.key == KeyS:
        if buffers[current].path.len > 0:
          buffers[current].ed.saveToFile(buffers[current].path)
        e = default Event  # consume the event
    else: discard

    discard title.draw(e, cells["title"], focus == "title")

    # Files panel -- click to switch buffer
    updateFilesPanel(files, buffers, current)
    discard files.draw(e, cells["files"], focus == "files")
    if e.kind == MouseDownEvent and focus == "files":
      let idx = files.currentLine
      if idx < buffers.len:
        current = idx
        focus = "editor"

    # Editor
    let edAct = buffers[current].ed.draw(e, cells["editor"], focus == "editor")
    case edAct.kind
    of ctrlClick:
      discard # TODO: language server lookup at edAct.pos
    of ctrlHover:
      discard # TODO: underline identifier at edAct.pos
    of noAction:
      buffers[current].ed.underline(-1, -1)

    # Terminal
    let termAct = term.draw(e, cells["terminal"], focus == "terminal")
    case termAct.kind
    of openFile:
      if fileExists(termAct.file):
        current = buffers.openFile(font, termAct.file, -1, -1)
        setWindowTitle("SynEdit - " & termAct.file.extractFilename)
        focus = "editor"
    of saveFile:
      if buffers[current].path.len > 0:
        buffers[current].ed.saveToFile(buffers[current].path)
    of ctrlHover:
      let (_, _, _, a, b) = term.ed.extractFilePosition(termAct.pos)
      term.ed.underline(a, b)
    of ctrlClick:
      term.ed.underline(-1, -1)
      handleTermCtrlClick(term.ed, termAct.pos, buffers, current,
                          font, term, focus)
    of noAction:
      term.ed.underline(-1, -1)

    # Status bar / prompt -- update prefix when not focused
    if focus != "status":
      updateStatus(status, buffers[current].ed, buffers[current].path)
    let statusAct = status.draw(e, cells["status"], focus == "status")
    case statusAct.kind
    of openFile:
      tryOpenFile(statusAct.file, buffers, current, font, focus)
      updateStatus(status, buffers[current].ed, buffers[current].path)
    of saveFile:
      if buffers[current].path.len > 0:
        buffers[current].ed.saveToFile(buffers[current].path)
      focus = "editor"
      updateStatus(status, buffers[current].ed, buffers[current].path)
    of ctrlHover, ctrlClick, noAction: discard

    refresh()

  closeFont(font)
  shutdown()

main()
