## editor.nim -- Example app demonstrating multiple SynEdit widgets
## with layout, labels, a code editor, and a terminal panel.
##
## Compile:
##   nim c examples/editor.nim

import std/tables
from std/cmdline import paramCount, paramStr
import ../src/uirelays
import ../src/uirelays/layout
import ../src/widgets/synedit

const appLayout = parseLayout("""
| title, 1 line                                   |
| editor, *       | terminal, *                    |
| status, 1 line                                   |
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

  var title, editor, terminal, status: SynEdit
  for w in [addr title, addr editor, addr terminal, addr status]:
    w[].init(font)

  title.setLabel("SynEdit Demo  --  editor (left) | terminal (right)")

  editor.lang = langNim
  editor.showLineNumbers = true
  if paramCount() >= 1:
    editor.loadFromFile(paramStr(1))
  else:
    editor.setText(sampleCode)

  terminal.lang = langConsole
  terminal.appendOutput("Welcome to the terminal.\n$ ")

  status.setLabel("Ready")

  editor.focused = true

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
      else: discard
    else:
      sleep(16)

    title.draw(e, cells["title"])
    editor.draw(e, cells["editor"])
    terminal.draw(e, cells["terminal"])
    status.draw(e, cells["status"])

    status.setLabel("Ln " & $(editor.currentLine + 1) &
                    ", Col " & $(editor.currentCol + 1) &
                    "  |  " & (if editor.changed: "modified" else: "saved"))

    refresh()

  closeFont(font)
  quitRequest()

main()
