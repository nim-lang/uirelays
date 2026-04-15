## editor.nim -- Example app demonstrating multiple SynEdit widgets
## with layout, labels, a code editor, and a terminal panel.
##
## Compile:
##   nim c examples/editor.nim

import std/[tables, os]
from std/cmdline import paramCount, paramStr
import uirelays
import uirelays/layout
import widgets/[synedit, terminal]

const appLayout = parseLayout("""
| title, 1 line                    |
| editor, *       | terminal, *    |
| status, 1 line                   |
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

proc handleTermCtrlClick(buf: SynEdit; pos: int;
                         editor: var SynEdit; term: var Terminal;
                         focus: var string) =
  let (file, ln, fc, a, b) = buf.extractFilePosition(pos)
  if file.len == 0: return
  let path = if isAbsolute(file): file else: os.getCurrentDir() / file
  # Set underline on the detected range
  term.ed.underline(a, b)
  if dirExists(path):
    os.setCurrentDir(path)
    setWindowTitle("SynEdit Demo - " & path)
    term.insertPrompt()
  elif fileExists(path):
    editor.loadFromFile(path)
    editor.lang = fileExtToLanguage(path.splitFile.ext)
    editor.showLineNumbers = true
    if ln >= 0:
      editor.gotoLine(ln, max(fc, 0))
    setWindowTitle("SynEdit - " & path.extractFilename)
    focus = "editor"

proc main =
  let screen = createWindow(1100, 700)
  var width = screen.width
  var height = screen.height

  var fm: FontMetrics
  let font = openFont("", 16, fm)
  setWindowTitle("SynEdit Demo")

  var title = createSynEdit(font)
  var editor = createSynEdit(font)
  var term = createTerminal(font)
  var status = createSynEdit(font)

  title.setLabel("SynEdit Demo  --  editor (left) | terminal (right)")

  editor.lang = langNim
  editor.showLineNumbers = true
  if paramCount() >= 1:
    editor.loadFromFile(paramStr(1))
  else:
    editor.setText(sampleCode)

  var focus = "editor"

  var running = true
  while running:
    let cells = appLayout.resolve(width, height, fm.lineHeight)

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
    else: discard

    discard title.draw(e, cells["title"], focus == "title")
    let edAct = editor.draw(e, cells["editor"], focus == "editor")
    if edAct.kind == ctrlClick:
      discard # TODO: language server lookup at edAct.pos
    elif edAct.kind == ctrlHover:
      discard # TODO: underline identifier at edAct.pos
    else:
      editor.underline(-1, -1)

    let termAct = term.draw(e, cells["terminal"], focus == "terminal")
    case termAct.kind
    of openFile:
      if fileExists(termAct.file):
        editor.loadFromFile(termAct.file)
        editor.lang = fileExtToLanguage(termAct.file.splitFile.ext)
        editor.showLineNumbers = true
        setWindowTitle("SynEdit - " & termAct.file.extractFilename)
        focus = "editor"
    of ctrlHover:
      let (_, _, _, a, b) = term.ed.extractFilePosition(termAct.pos)
      term.ed.underline(a, b)
    of ctrlClick:
      term.ed.underline(-1, -1)
      handleTermCtrlClick(term.ed, termAct.pos, editor, term, focus)
    of noAction:
      term.ed.underline(-1, -1)

    status.setLabel("Ln " & $(editor.currentLine + 1) &
                    ", Col " & $(editor.currentCol + 1) &
                    "  |  " & (if editor.changed: "modified" else: "saved"))
    discard status.draw(e, cells["status"], focus == "status")

    refresh()

  closeFont(font)
  shutdown()

main()
