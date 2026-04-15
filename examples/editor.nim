## editor.nim -- Example app demonstrating multiple SynEdit widgets
## with layout, labels, a code editor, and a terminal panel.
##
## Compile:
##   nim c examples/editor.nim

import std/tables
from std/cmdline import paramCount, paramStr
import uirelays
import uirelays/layout
import widgets/[synedit, terminal, label]

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

  var title = createLabel(font, "SynEdit Demo  --  editor (left) | terminal (right)")
  var editor = createSynEdit(font)
  var term = createTerminal(font)
  var status = createLabel(font)

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

    title.draw(cells["title"])
    discard editor.draw(e, cells["editor"], focus == "editor")
    let termAct = term.draw(e, cells["terminal"], focus == "terminal")
    if termAct.kind == openFile:
      editor.loadFromFile(termAct.file)
      focus = "editor"

    status.text = "Ln " & $(editor.currentLine + 1) &
                  ", Col " & $(editor.currentCol + 1) &
                  "  |  " & (if editor.changed: "modified" else: "saved")
    status.draw(cells["status"])

    refresh()

  closeFont(font)
  shutdown()

main()
