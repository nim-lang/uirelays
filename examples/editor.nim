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

const appLayout = parseLayout("""
| title, 1 line                                   |
| editor, *       | terminal, *                    |
| status, 1 line                                   |
""")

proc main =
  let screen = createWindow(1100, 700)
  var width = screen.width
  var height = screen.height

  var fm: FontMetrics
  let font = openFont("", 16, fm)
  setWindowTitle("SynEdit Demo")

  let theme = catppuccinMocha()

  # Title bar -- read-only label
  var title: SynEdit
  title.init(font, theme)
  title.setText("SynEdit Demo  --  editor (left) | terminal (right)")
  title.readOnly = title.len - 1

  # Code editor
  var editor: SynEdit
  editor.init(font, theme)
  editor.lang = langNim
  editor.showLineNumbers = true
  if paramCount() >= 1:
    editor.loadFromFile(paramStr(1))
  else:
    editor.setText(sampleCode)

  # Terminal panel
  var terminal: SynEdit
  terminal.init(font, theme)
  terminal.lang = langConsole
  terminal.appendOutput("Welcome to the terminal.\n$ ")

  # Status bar -- read-only label
  var status: SynEdit
  status.init(font, theme)
  status.setText("Ready")
  status.readOnly = status.len - 1

  editor.focused = true  # editor starts with focus

  var running = true
  while running:
    let cells = appLayout.resolve(width, height, fm.lineHeight)

    # process all pending events, routing each through every widget
    var e: Event
    while pollEvent(e, {WantTextInput}):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowResizeEvent:
        width = e.x
        height = e.y
      else:
        # each widget's draw handles focus via mouse clicks
        title.draw(e, cells["title"])
        editor.draw(e, cells["editor"])
        terminal.draw(e, cells["terminal"])
        status.draw(e, cells["status"])

    # render frame with a no-event pass
    var noEvent: Event
    title.draw(noEvent, cells["title"])
    editor.draw(noEvent, cells["editor"])
    terminal.draw(noEvent, cells["terminal"])
    status.draw(noEvent, cells["status"])

    # update status bar with cursor position
    let line = editor.currentLine + 1
    let col = editor.currentCol + 1
    status.readOnly = -1
    status.setText("Ln " & $line & ", Col " & $col &
                   "  |  " & (if editor.changed: "modified" else: "saved"))
    status.readOnly = status.len - 1

    refresh()
    sleep(16)

  closeFont(font)
  quitRequest()

main()
