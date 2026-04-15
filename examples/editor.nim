## editor.nim -- Example app demonstrating multiple SynEdit widgets
## with layout, labels, a code editor, and a terminal panel.
##
## Compile:
##   nim c examples/editor.nim

import std/tables
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

  status.setLabel("Ready")

  type Focus = enum
    focusEditor, focusTerminal

  var focus = focusEditor

  var running = true
  while running:
    let cells = appLayout.resolve(width, height, fm.lineHeight)

    var e = default Event
    if pollEvent(e, {WantTextInput}):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowResizeEvent:
        width = e.x
        height = e.y
      of MouseDownEvent:
        if cells["editor"].contains(point(e.x, e.y)):
          focus = focusEditor
        elif cells["terminal"].contains(point(e.x, e.y)):
          focus = focusTerminal
      else: discard
    else:
      sleep(16)

    # Labels: passive draw, no event overload
    title.draw(cells["title"])
    status.draw(cells["status"])

    # Focused widget gets draw(event, area), unfocused gets draw(area)
    case focus
    of focusEditor:
      discard editor.draw(e, cells["editor"])
      term.draw(cells["terminal"])
    of focusTerminal:
      editor.draw(cells["editor"])
      let termAct = term.draw(e, cells["terminal"])
      if termAct.kind == openFile:
        editor.loadFromFile(termAct.file)
        focus = focusEditor

    status.setLabel("Ln " & $(editor.currentLine + 1) &
                    ", Col " & $(editor.currentCol + 1) &
                    "  |  " & (if editor.changed: "modified" else: "saved"))

    refresh()

  closeFont(font)
  quitRequest()

main()
