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

Instead of a classical tab bar and a tree view there are two more edit fields,
each with its own *flipped* edit semantics:

- **Tab list**: every line is an open tab, and the line text is nothing but
  the file name. Click or Enter activates, deleting a line closes the tab,
  moving a line reorders the tabs, and undo (Ctrl+Z) reopens a closed tab --
  all of it falls out of the ordinary editing operations. State that is not a
  name (active, modified) lives in markers, never in the text, so that
  delete/copy/paste keep operating on a clean list.
- **Explorer**: a flat listing of one directory. Here it is the *first* line
  that is editable: it doubles as the path field and as a filter. Typing
  narrows the listing, Enter on a directory descends into it, and Enter on a
  partial name accepts the first match -- so there is no need for a modal
  "open file" dialog.

The same idea applied to the window itself: tab 0 is `[layout]`, and its text
IS the layout table this app is built from. Editing it relayouts the window on
the next frame, so there is no separate settings dialog either. Leaving a
widget out of the table hides it without destroying it -- its buffer, cursor
and scroll position are still there when a later layout lists it again. Only
the `editor` cell has to stay, since it is where the layout gets typed. A table
that does not parse is reported in the status bar and ignored, so the last good
layout keeps the window usable.

The layout and the list of open tabs are stored under `getConfigDir()` in
`relayedit/layout.md` and `relayedit/tabs.txt`, so both survive a restart.
]##

import std/[tables, os, algorithm]
from std/strutils import toLowerAscii, strip, endsWith, contains, splitLines
from std/cmdline import paramCount, paramStr
import uirelays
import uirelays/layout
import widgets/[synedit, terminal]

const defaultLayout = """
| title, 1 line                                                                     |
| tabs, 6 lines, 200px ; explorer, * | editor, 3* | history, 5 lines, 2* ; terminal, * |
| status, 1 line                                                                    |
"""

const
  PathChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '.', '/', '\\',
               '-', '~', '\128'..'\255'}
  # Font sizes are *logical*: `fontForSize` turns them into physical ones with
  # the display's `uiScale`, so 16 looks the same on a 4K laptop panel as on a
  # 96 dpi monitor, and Ctrl+plus/minus steps by the same apparent amount on
  # both.
  DefaultFontSize = 16
  MinFontSize = 8
  MaxFontSize = 56
  ## A layout may leave any widget out -- it is then simply not drawn, and
  ## keeps its state until a later layout brings it back. Only the editor
  ## has to stay: without it there is nowhere to type the layout back.
  RequiredCells = ["editor"]
  ConfigDirName = "relayedit"

proc configPath(name: string): string =
  getConfigDir() / ConfigDirName / name

proc saveConfig(name, text: string) =
  ## Best effort: an unwritable config dir must not take the editor down.
  try:
    createDir(getConfigDir() / ConfigDirName)
    writeFile(configPath(name), text)
  except CatchableError:
    discard

proc loadConfig(name: string): string =
  try:
    result = readFile(configPath(name))
  except CatchableError:
    result = ""

var gUiScale = 100
  ## Percent to enlarge text by on this display, from `ScreenLayout.uiScale`.
  ## A global because every `fontForSize` call needs it and none of them cares
  ## about anything else the window knows.

proc fontForSize(fonts: var Table[int, Font]; size: int): Font =
  ## `size` and the cache key are logical; only what reaches `openFont` is
  ## physical.
  let clamped = clamp(size, MinFontSize, MaxFontSize)
  if clamped notin fonts:
    var metrics: FontMetrics
    fonts[clamped] = openFont("", clamped * gUiScale div 100, metrics)
  result = fonts[clamped]

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
    path: string        ## "" for generated buffers
    isLayout: bool      ## this buffer's text IS the window layout

proc newBuffer(font: Font; path: string): BufferEntry =
  var ed = createSynEdit(font)
  ed.showLineNumbers = true
  let ext = path.splitFile.ext.toLowerAscii
  ed.lang = fileExtToLanguage(ext)
  ed.flags = {rfColorLiterals}
  if ext == ".md" or ext == ".markdown":
    ed.flags.incl rfMarkdownImages
  # The explorer makes it easy to click anything at all, so a file that
  # cannot be read must not take the editor down with it.
  try:
    ed.loadFromFile(path)
    if ed.len == 0 and getFileSize(path) > 0:
      # loadFromFile silently refuses binaries; say so instead of showing
      # an empty buffer.
      ed.lang = langNone
      ed.setText(path.extractFilename & ": binary file, not shown")
      ed.readOnly = ed.len - 1
  except CatchableError:
    ed.lang = langNone
    ed.setText("cannot read " & path & ": " & getCurrentExceptionMsg())
    ed.readOnly = ed.len - 1
  result = BufferEntry(ed: ed, path: path)

proc tabsText(buffers: seq[BufferEntry]): string =
  ## The open tabs, in tab order. Generated buffers have no path and so are
  ## not part of the session.
  result = ""
  for b in buffers:
    if b.path.len > 0: result.add b.path & "\n"

proc openFile(buffers: var seq[BufferEntry]; font: Font;
              path: string; line, col: int): int =
  ## Open a file or switch to it if already open. Returns the buffer index.
  for i, b in buffers:
    if b.path == path:
      if line >= 0: buffers[i].ed.gotoLine(line, max(col, 0))
      return i
  buffers.add newBuffer(font, path)
  if line >= 0: buffers[^1].ed.gotoLine(line, max(col, 0))
  result = buffers.high

# ---------------------------------------------------------------------------
# Tab list -- an edit field whose lines ARE the open tabs
# ---------------------------------------------------------------------------

type
  ClosedTab = object
    name, path: string

  TabList = object
    ed: SynEdit
    names: seq[string]     ## display name per buffer, as last rendered
    closed: seq[ClosedTab] ## closed tabs, so that undo can reopen them
    note: string           ## why the last close was refused ("" = nothing)

proc displayNames(buffers: seq[BufferEntry]): seq[string] =
  ## One unique name per buffer. Uniqueness matters: the name is the only
  ## handle we have once the user has edited the list.
  var base: seq[string] = @[]
  for b in buffers:
    base.add(
      if b.isLayout: "[layout]"
      elif b.path.len > 0: b.path.extractFilename
      else: "[scratch]")
  result = @[]
  for i, n in base:
    var dup = false
    for j, m in base:
      if i != j and n == m: dup = true
    if dup and buffers[i].path.len > 0:
      let parent = buffers[i].path.parentDir.lastPathPart
      result.add(if parent.len > 0: parent & "/" & n else: n)
    else:
      result.add n
  for i in 0 ..< result.len:
    for j in 0 ..< i:
      if result[i] == result[j]:
        result[i] = result[i] & " #" & $(i + 1)

proc renderTabs(tabs: var TabList; buffers: seq[BufferEntry]) =
  ## Rebuild the buffer text from the model. This resets the undo stack, so
  ## it must only run when the model changed behind the tab list's back --
  ## never after an edit the user made *in* the tab list.
  tabs.names = displayNames(buffers)
  var text = ""
  for i, n in tabs.names:
    if i > 0: text.add "\n"
    text.add n
  let line = tabs.ed.currentLine
  tabs.ed.setText(text)
  tabs.ed.gotoLine(min(line, max(0, tabs.names.len - 1)) + 1, 0)

proc decorateTabs(tabs: var TabList; buffers: seq[BufferEntry]; current: int) =
  ## Active and modified state as markers, not as text. Offsets are derived
  ## from the names because the text is exactly `names` joined by newlines.
  let theme = tabs.ed.theme
  tabs.ed.clearMarkers()
  var pos = 0
  for i, n in tabs.names:
    if i == current:
      tabs.ed.addMarker(pos, pos + n.len - 1, theme.activeLineBg)
    pos += n.len + 1
  pos = 0
  for i, n in tabs.names:
    # The layout buffer never shows up here: the main loop consumes its changed
    # flag on the very next frame, which is also when it gets stored.
    if i < buffers.len and buffers[i].ed.changed:
      tabs.ed.addMarker(pos, pos + n.len - 1, theme.markerBg)
    pos += n.len + 1

proc applyTabEdits(tabs: var TabList; buffers: var seq[BufferEntry];
                   current: var int; font: Font) =
  ## Diff the buffer's lines against the model and apply the difference:
  ##   line gone      -> close that tab
  ##   lines reordered -> reorder the tabs
  ##   line back again -> reopen it (this is what makes Ctrl+Z work)
  if tabs.names.len != buffers.len: return
  var lines: seq[string] = @[]
  for i in 0 ..< tabs.ed.getLineCount():
    let t = tabs.ed.getLineText(i).strip()
    if t.len > 0: lines.add t
  if lines == tabs.names:
    # Blank lines are not tabs; drop them again.
    if tabs.ed.getLineCount() != tabs.names.len: renderTabs(tabs, buffers)
    return

  tabs.note = ""
  let currentName = if current < tabs.names.len: tabs.names[current] else: ""
  var order: seq[BufferEntry] = @[]
  var newNames: seq[string] = @[]
  var taken = newSeq[bool](buffers.len)
  for ln in lines:
    var idx = -1
    for i, n in tabs.names:
      if not taken[i] and n == ln:
        idx = i
        break
    if idx >= 0:
      taken[idx] = true
      order.add buffers[idx]
      newNames.add ln
    else:
      # A line the model does not know: an undone close, or a pasted path.
      var path = ""
      for c in tabs.closed:
        if c.name == ln: path = c.path
      if path.len == 0:
        let p = if isAbsolute(ln): ln else: os.getCurrentDir() / ln
        if fileExists(p): path = p
      if path.len > 0 and fileExists(path):
        order.add newBuffer(font, path)
        newNames.add ln

  # Some tabs refuse to close: put their line back.
  for i in 0 ..< tabs.names.len:
    if not taken[i]:
      if buffers[i].isLayout:
        # Closing it would leave no way to edit the layout back.
        tabs.note = "the layout buffer stays open"
      elif buffers[i].path.len > 0 and buffers[i].ed.changed:
        # A buffer without a path cannot be saved, so the guard would be
        # a trap rather than a warning.
        tabs.note = tabs.names[i] & ": unsaved changes, Ctrl+S first"
      else:
        continue
      renderTabs(tabs, buffers)
      return
  if order.len == 0:
    # The last tab stays open.
    renderTabs(tabs, buffers)
    return

  for i in 0 ..< tabs.names.len:
    if not taken[i] and buffers[i].path.len > 0:
      tabs.closed.add ClosedTab(name: tabs.names[i], path: buffers[i].path)
  buffers = order
  tabs.names = newNames
  current = clamp(current, 0, buffers.high)
  for i, n in newNames:
    if n == currentName: current = i

proc reparseLayout(src: string; width, height, lineHeight: int;
                   layout: var Layout; note: var string) =
  ## The layout buffer's text IS the layout. A layout that does not parse,
  ## or that loses a cell the app needs, is reported and dropped -- the last
  ## good one keeps the window usable so the text can be corrected.
  var parsed: Layout
  try:
    parsed = parseLayout(src)
  except CatchableError:
    note = "layout: " & getCurrentExceptionMsg()
    return
  var cells: Table[string, Rect]
  try:
    cells = parsed.resolve(width, height, lineHeight, gap = 2)
  except CatchableError:
    note = "layout: " & getCurrentExceptionMsg()
    return
  for name in RequiredCells:
    if name notin cells:
      note = "layout: no '" & name & "' cell"
      return
  layout = parsed
  note = ""

# ---------------------------------------------------------------------------
# Explorer -- a flat listing of one directory, with an editable path line
# ---------------------------------------------------------------------------

type
  Explorer = object
    ed: SynEdit
    dir: string          ## the directory currently listed
    base: string         ## anchor for resolving the path line; only explicit
                         ## navigation moves it, so typing stays predictable
    entries: seq[string] ## the lines below the header, in order
    header: string       ## line 0, as last rendered

proc normDir(dir: string): string =
  result = dir
  while result.len > 1 and result[^1] == DirSep:
    result.setLen result.len - 1
  if result.len == 0: result = $DirSep

proc resolveIn(base, s: string): string =
  ## Resolve the path line against `base`. A bare word like "syn" becomes
  ## `base/syn`, whose parent is `base` -- which is what turns it into a
  ## filter over the current listing.
  let e = expandTilde(s.strip())
  if e.len == 0: return ""
  result = if isAbsolute(e): e else: base / e

proc listDir(dir, filter: string): seq[string] =
  ## ".." first, then directories, then files. Dotfiles are hidden.
  var dirs: seq[string] = @[]
  var files: seq[string] = @[]
  let f = filter.toLowerAscii
  for kind, path in walkDir(dir):
    let name = path.extractFilename
    if name.len == 0 or name[0] == '.': continue
    if f.len > 0 and not name.toLowerAscii.contains(f): continue
    case kind
    of pcDir, pcLinkToDir: dirs.add name & $DirSep
    else: files.add name
  sort dirs
  sort files
  result = @[]
  if filter.len == 0: result.add ".."
  for d in dirs: result.add d
  for x in files: result.add x

proc renderExplorer(ex: var Explorer; header: string; cursorPos: int) =
  ex.header = header
  var text = header
  for e in ex.entries: text.add "\n" & e
  ex.ed.setText(text)
  ex.ed.gotoPos(clamp(cursorPos, 0, text.len))

proc showDir(ex: var Explorer; dir: string) =
  if not dirExists(dir): return
  ex.dir = normDir(dir)
  ex.base = ex.dir
  ex.entries = listDir(ex.dir, "")
  let h = ex.dir & (if ex.dir.endsWith($DirSep): "" else: $DirSep)
  ex.renderExplorer(h, h.len)

proc applyHeader(ex: var Explorer; header: string) =
  ## The path line doubles as "cd" and as a filter: an existing directory
  ## switches the listing, anything else narrows it.
  let full = resolveIn(ex.base, header)
  var dir = ex.base
  var filter = ""
  if full.len > 0 and dirExists(full):
    dir = full
  elif full.len > 0:
    let parent = full.parentDir
    if parent.len > 0 and dirExists(parent):
      dir = parent
      filter = full.extractFilename
  ex.dir = normDir(dir)
  ex.entries = listDir(ex.dir, filter)
  ex.renderExplorer(header, ex.ed.cursor)

proc activateEntry(ex: var Explorer; name: string;
                   buffers: var seq[BufferEntry]; current: var int;
                   font: Font; focus: var string) =
  if name == "..":
    let up = ex.dir.parentDir
    if up.len > 0: ex.showDir(up)
  elif name.endsWith($DirSep):
    ex.showDir(ex.dir / name[0 ..< name.len - 1])
  else:
    let p = ex.dir / name
    if fileExists(p):
      current = buffers.openFile(font, p, -1, -1)
      setWindowTitle("SynEdit - " & name)
      focus = "editor"

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

proc updateStatus(status: var Terminal; ed: SynEdit; path, note: string) =
  let name = if path.len > 0: path.extractFilename else: "[scratch]"
  let info = name & "  Ln " & $(ed.currentLine + 1) &
             ", Col " & $(ed.currentCol + 1) &
             (if ed.changed: "  *" else: "") &
             (if note.len > 0: "  " & note else: "") & " > "
  status.ed.clear()
  status.ed.lang = langConsole
  status.ed.appendOutput(info)

proc addHistoryLine(history: var SynEdit; cmd: string) =
  ## Append a command to the history panel as an ordinary edit, so that the (x)
  ## button, a hand-made deletion and Ctrl+Z all act on it the same way. An
  ## existing copy moves to the end instead of being repeated -- the list is
  ## there to save typing, not to record every repetition.
  if cmd.len == 0: return
  for i in 0 ..< history.getLineCount():
    if history.getLineText(i) == cmd:
      history.gotoLine(i + 1, 0)
      history.deleteLine()
      break
  history.gotoPos(history.len)
  # One insertText, so one Ctrl+Z takes the whole row back out again.
  history.insertText(if history.len > 0: "\n" & cmd else: cmd)

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

proc adjustFocusedFontSize(
    focus: string; delta: int;
    fonts: var Table[int, Font];
    title, history: var SynEdit;
    tabs: var TabList; explorer: var Explorer;
    term, status: var Terminal;
    buffers: var seq[BufferEntry]; current: int;
    titleFontSize, panelFontSize, historyFontSize,
    terminalFontSize, statusFontSize, editorFontSize: var int) =
  case focus
  of "title":
    titleFontSize = clamp(titleFontSize + delta, MinFontSize, MaxFontSize)
    title.setFont(fonts.fontForSize(titleFontSize))
  of "tabs", "explorer":
    panelFontSize = clamp(panelFontSize + delta, MinFontSize, MaxFontSize)
    let f = fonts.fontForSize(panelFontSize)
    tabs.ed.setFont(f)
    explorer.ed.setFont(f)
  of "history":
    historyFontSize = clamp(historyFontSize + delta, MinFontSize, MaxFontSize)
    history.setFont(fonts.fontForSize(historyFontSize))
  of "terminal":
    terminalFontSize = clamp(terminalFontSize + delta, MinFontSize, MaxFontSize)
    term.ed.setFont(fonts.fontForSize(terminalFontSize))
  of "status":
    statusFontSize = clamp(statusFontSize + delta, MinFontSize, MaxFontSize)
    status.ed.setFont(fonts.fontForSize(statusFontSize))
  of "editor":
    editorFontSize = clamp(editorFontSize + delta, MinFontSize, MaxFontSize)
    let newFont = fonts.fontForSize(editorFontSize)
    for i in 0 ..< buffers.len:
      buffers[i].ed.setFont(newFont)
  else:
    discard


proc main =
  let screen = createWindow(1100, 700)
  var width = screen.width
  var height = screen.height
  gUiScale = screen.uiScale

  var fonts: Table[int, Font]
  let font = fonts.fontForSize(DefaultFontSize)
  var fm = getFontMetrics(font)
  setWindowTitle("SynEdit Demo")

  var title = createSynEdit(font)
  var history = createSynEdit(font)
  var term = createTerminal(font)
  var status = createTerminal(font)
  var tabs = TabList(ed: createSynEdit(font))
  var explorer = Explorer(ed: createSynEdit(font))
  tabs.ed.lang = langNone
  explorer.ed.lang = langNone
  # Every tab list line acts on click; in the explorer line 0 is the path
  # field, so only the listing below it does.
  tabs.ed.setActionLines(0)
  explorer.ed.setActionLines(1)
  tabs.ed.setCloseButtons(0)
  # The history panel is a list of commands to act on, exactly like the tab
  # list, so it gets the same framed rows and the same (x) -- which here forgets
  # the command and frees the row for a newer one. `langNone` for the same
  # reason the tab list uses it: a row is a label, not code to colorize.
  history.setActionLines(0)
  history.setCloseButtons(0)
  history.lang = langNone
  var titleFontSize = DefaultFontSize
  var panelFontSize = DefaultFontSize
  var historyFontSize = DefaultFontSize
  var terminalFontSize = DefaultFontSize
  var statusFontSize = DefaultFontSize
  var editorFontSize = DefaultFontSize

  title.setLabel("SynEdit Demo -- edit the [layout] tab to relayout this window")

  # The layout the window starts with: whatever was stored last time, unless
  # it no longer works -- then the default, with the reason in the status bar.
  var layout = parseLayout(defaultLayout)
  var layoutNote = ""
  var layoutText = loadConfig("layout.md")
  if layoutText.len > 0:
    reparseLayout(layoutText, width, height, fm.lineHeight, layout, layoutNote)
    if layoutNote.len > 0:
      layoutNote = "stored " & configPath("layout.md") & " ignored -- " &
                   layoutNote
      layoutText = defaultLayout
  else:
    layoutText = defaultLayout

  # Buffer list. The layout buffer is tab 0: editing it relayouts the window
  # on the next frame. The rest of the tabs are last session's.
  var buffers: seq[BufferEntry]
  var current = 0
  block:
    var ed = createSynEdit(fonts.fontForSize(editorFontSize))
    ed.lang = langMarkdown
    ed.showLineNumbers = true
    ed.setText(layoutText)
    buffers.add BufferEntry(ed: ed, path: "", isLayout: true)
  for line in loadConfig("tabs.txt").splitLines:
    let p = line.strip
    if p.len > 0 and fileExists(p):
      discard buffers.openFile(fonts.fontForSize(editorFontSize), p, -1, -1)
  if paramCount() >= 1:
    current = buffers.openFile(fonts.fontForSize(editorFontSize), paramStr(1), -1, -1)
  elif buffers.len > 1:
    current = 1

  var savedTabs = tabsText(buffers)

  renderTabs(tabs, buffers)
  explorer.showDir(
    if buffers[current].path.len > 0: buffers[current].path.parentDir
    else: os.getCurrentDir())
  var lastCurrent = current

  var focus = "editor"

  var running = true
  while running:
    # Pick up edits to the layout buffer before resolving, so that the rects
    # and the hit tests within one frame always come from the same layout.
    # The buffer's own changed flag is the signal; consuming it here re-parses
    # once per edit, whether the new table works out or not.
    for b in buffers.mitems:
      if b.isLayout and b.ed.changed:
        let src = b.ed.fullText
        reparseLayout(src, width, height, fm.lineHeight, layout, layoutNote)
        if layoutNote.len == 0: saveConfig("layout.md", src)
        b.ed.markSaved()

    let cells = layout.resolve(width, height, fm.lineHeight, gap = 2)
    # A layout may have dropped the cell that had the focus.
    if focus notin cells: focus = "editor"

    # Fill background -- gaps between cells show this color as borders
    fillRect(rect(0, 0, width, height), color(200, 200, 200))

    var e = default Event
    discard waitEvent(e, 500, {WantTextInput})
    case e.kind
    of QuitEvent, WindowCloseEvent:
      running = false
    of WindowResizeEvent, WindowMetricsEvent:
      width = e.x
      height = e.y
      if e.kind == WindowMetricsEvent and e.uiScale > 0 and e.uiScale != gUiScale:
        # Dragged onto a display of another density. The logical sizes stay put
        # and only their physical counterparts change, so every font that is
        # already open has to be reopened at the new scale.
        gUiScale = e.uiScale
        for f in fonts.values: closeFont(f)
        fonts.clear()
        title.setFont(fonts.fontForSize(titleFontSize))
        let panelFont = fonts.fontForSize(panelFontSize)
        tabs.ed.setFont(panelFont)
        explorer.ed.setFont(panelFont)
        history.setFont(fonts.fontForSize(historyFontSize))
        term.ed.setFont(fonts.fontForSize(terminalFontSize))
        status.ed.setFont(fonts.fontForSize(statusFontSize))
        let editorFont = fonts.fontForSize(editorFontSize)
        for i in 0 ..< buffers.len:
          buffers[i].ed.setFont(editorFont)
        fm = getFontMetrics(fonts.fontForSize(DefaultFontSize))
    of MouseDownEvent:
      let hit = cells.hitTest(e.x, e.y)
      if hit.name.len > 0:
        focus = hit.name
    of KeyDownEvent:
      let cmd = CtrlPressed in e.mods or GuiPressed in e.mods
      if cmd and e.key == KeyS:
        if buffers[current].path.len > 0:
          buffers[current].ed.saveToFile(buffers[current].path)
        tabs.note = ""
        e = default Event  # consume the event
      elif cmd and e.key == KeyW:
        # Close the current tab by deleting its line, so that it goes through
        # the tab list's undo stack like a hand-made deletion would.
        tabs.ed.gotoLine(current + 1, 0)
        tabs.ed.deleteLine()
        e = default Event  # consume the event
      elif cmd and (e.key == KeyEqual or e.key == KeyPlus or e.key == KeyMinus):
        let delta = if e.key == KeyMinus: -1 else: 1
        adjustFocusedFontSize(focus, delta, fonts, title, history,
                              tabs, explorer, term, status, buffers, current,
                              titleFontSize, panelFontSize, historyFontSize,
                              terminalFontSize, statusFontSize, editorFontSize)
        e = default Event  # consume the event
      elif e.key == KeyEnter and focus == "tabs":
        # Enter activates a tab instead of inserting a newline.
        let idx = tabs.ed.currentLine
        if idx < buffers.len:
          current = idx
          focus = "editor"
        e = default Event
      elif e.key == KeyEnter and focus == "explorer":
        let line = explorer.ed.currentLine
        if line == 0:
          let full = resolveIn(explorer.base, explorer.ed.getLineText(0))
          if full.len > 0 and dirExists(full):
            explorer.showDir(full)
          elif full.len > 0 and fileExists(full):
            current = buffers.openFile(fonts.fontForSize(editorFontSize),
                                       full, -1, -1)
            setWindowTitle("SynEdit - " & full.extractFilename)
            focus = "editor"
          elif explorer.entries.len > 0:
            # A partial name accepts the first match.
            explorer.activateEntry(explorer.entries[0], buffers, current,
                                   fonts.fontForSize(editorFontSize), focus)
        elif line - 1 < explorer.entries.len:
          explorer.activateEntry(explorer.entries[line - 1], buffers, current,
                                 fonts.fontForSize(editorFontSize), focus)
        e = default Event
    else: discard

    # Widgets the layout leaves out are simply not drawn. They keep their
    # state, so they come back exactly as they were once a layout lists
    # them again.
    if "title" in cells:
      discard title.draw(e, cells["title"], focus == "title")

    # Tab list -- its lines ARE the open tabs. The bookkeeping runs even when
    # the list is hidden, because Ctrl+W still edits its buffer.
    if tabs.names != displayNames(buffers): renderTabs(tabs, buffers)
    decorateTabs(tabs, buffers, current)
    var tabAct = EditAction(kind: noAction)
    if "tabs" in cells:
      tabAct = tabs.ed.draw(e, cells["tabs"], focus == "tabs")
    if tabAct.kind == closeLine:
      # The (x) deletes the line, so closing by button and closing by hand
      # end up in the same undo stack.
      tabs.ed.gotoLine(tabAct.line + 1, 0)
      tabs.ed.deleteLine()
    applyTabEdits(tabs, buffers, current, fonts.fontForSize(editorFontSize))
    if e.kind == MouseDownEvent and focus == "tabs" and
       tabAct.kind != closeLine:
      let idx = tabs.ed.currentLine
      if idx < buffers.len:
        current = idx
        focus = "editor"

    # Explorer -- flat directory listing, line 0 is the path/filter field
    let exFocused = focus == "explorer"
    if "explorer" in cells:
      discard explorer.ed.draw(e, cells["explorer"], exFocused)
      if exFocused:
        if e.kind == MouseDownEvent:
          let line = explorer.ed.currentLine
          if line > 0 and line - 1 < explorer.entries.len:
            explorer.activateEntry(explorer.entries[line - 1], buffers, current,
                                   fonts.fontForSize(editorFontSize), focus)
        else:
          let header = explorer.ed.getLineText(0)
          if header != explorer.header:
            explorer.applyHeader(header)
          elif explorer.ed.getLineCount() != explorer.entries.len + 1:
            # The listing itself is not editable; put it back.
            explorer.renderExplorer(explorer.header, explorer.ed.cursor)

    # The explorer follows the directory of the active file.
    if current != lastCurrent:
      lastCurrent = current
      let p = buffers[current].path
      if p.len > 0 and normDir(p.parentDir) != explorer.dir:
        explorer.showDir(p.parentDir)

    # Editor
    let edAct = buffers[current].ed.draw(e, cells["editor"], focus == "editor")
    case edAct.kind
    of ctrlClick:
      discard # TODO: language server lookup at edAct.pos
    of ctrlHover:
      discard # TODO: underline identifier at edAct.pos
    of closeLine:
      discard # the editor has no close buttons
    of noAction:
      buffers[current].ed.underline(-1, -1)

    # History panel -- its lines ARE the command list, so a click re-runs a line
    # and the (x) deletes one. The ingest runs even when the layout leaves the
    # panel out, so nothing typed while it was hidden goes missing.
    for cmd in term.ran: history.addHistoryLine(cmd)
    term.ran.setLen 0
    if "history" in cells:
      let histAct = history.draw(e, cells["history"], focus == "history")
      if histAct.kind == closeLine:
        # Same as the tab list: the button deletes the line, so closing by
        # button and closing by hand share one undo stack.
        history.gotoLine(histAct.line + 1, 0)
        history.deleteLine()
      elif e.kind == MouseDownEvent and focus == "history":
        # Only a click on the row itself re-runs it: the (x) took the branch
        # above and must not activate what it is removing.
        var cmd = history.getLineText(history.currentLine)
        if cmd.len > 0:
          discard term.runCommand(cmd)
          focus = "terminal"

    # Terminal
    var termAct = TermAction(kind: noAction)
    if "terminal" in cells:
      termAct = term.draw(e, cells["terminal"], focus == "terminal")
    case termAct.kind
    of openFile:
      if fileExists(termAct.file):
        current = buffers.openFile(fonts.fontForSize(editorFontSize), termAct.file, -1, -1)
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
                          fonts.fontForSize(editorFontSize), term, focus)
    of noAction:
      term.ed.underline(-1, -1)

    # Status bar / prompt -- update prefix when not focused
    # A broken layout is the more urgent of the two notes: it is what the
    # user is looking at while typing in the [layout] tab.
    let note = if layoutNote.len > 0: layoutNote else: tabs.note
    if focus != "status":
      updateStatus(status, buffers[current].ed, buffers[current].path, note)
    var statusAct = TermAction(kind: noAction)
    if "status" in cells:
      statusAct = status.draw(e, cells["status"], focus == "status")
    case statusAct.kind
    of openFile:
      tryOpenFile(statusAct.file, buffers, current,
                  fonts.fontForSize(editorFontSize), focus)
      updateStatus(status, buffers[current].ed, buffers[current].path, note)
    of saveFile:
      if buffers[current].path.len > 0:
        buffers[current].ed.saveToFile(buffers[current].path)
      focus = "editor"
      updateStatus(status, buffers[current].ed, buffers[current].path, note)
    of ctrlHover, ctrlClick, noAction: discard

    # Persist the session once everything that could have changed it has run.
    let tt = tabsText(buffers)
    if tt != savedTabs:
      savedTabs = tt
      saveConfig("tabs.txt", tt)

    refresh()

  for _, f in fonts:
    closeFont(f)
  shutdown()

main()
