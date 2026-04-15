## Terminal -- command console widget for uirelays.
##
## Ported from nimedit's console component. Wraps a SynEdit in
## ``langConsole`` mode and adds command execution, history, and
## tab completion.
##
## Usage::
##
##   var term = createTerminal(font)
##   # in your main loop:
##   term.draw(e, rect(0, 0, 600, 400))
##
## The terminal runs commands in a background thread and streams
## their output into the editor buffer.

import std/[os, osproc, streams, strutils, tables, browsers]
import synedit
import ../uirelays/[coords, screen, input]

export synedit

# ---------------------------------------------------------------------------
# File filtering (for tab completion)
# ---------------------------------------------------------------------------

const
  ExtensionsToIgnore* = [
    ".ppu", ".o", ".obj", ".dcu",
    ".map", ".tds", ".err", ".bak", ".pyc", ".exe", ".rod", ".pdb", ".idb",
    ".idx", ".ilk", ".dll", ".so", ".a"
  ]

proc ignoreFile(f: string): bool =
  let (_, name, ext) = f.splitFile
  result = name.len > 0 and name[0] == '.' or ext in ExtensionsToIgnore or
           f == "nimcache"

# ---------------------------------------------------------------------------
# Command history
# ---------------------------------------------------------------------------

type
  CmdHistory* = object
    cmds*: seq[string]
    suggested*: int

proc addCmd(h: var CmdHistory; cmd: string) =
  var replaceWith = -1
  for i in 0..high(h.cmds):
    if h.cmds[i] == cmd:
      swap(h.cmds[i], h.cmds[^1])
      h.suggested = h.cmds.high
      return
    elif h.cmds[i] in cmd:
      if replaceWith < 0 or h.cmds[replaceWith] < h.cmds[i]:
        replaceWith = i
  if replaceWith < 0:
    h.cmds.add cmd
  else:
    h.cmds[replaceWith] = cmd

proc suggest(h: var CmdHistory; up: bool): string =
  if h.suggested < 0 or h.suggested >= h.cmds.len:
    h.suggested = (if up: h.cmds.high else: 0)
  if h.suggested >= 0 and h.suggested < h.cmds.len:
    result = h.cmds[h.suggested]
    h.suggested += (if up: -1 else: 1)
  else:
    result = ""

# ---------------------------------------------------------------------------
# Command parsing helpers
# ---------------------------------------------------------------------------

proc handleHexChar(s: string; pos: int; xi: var int): int =
  case s[pos]
  of '0'..'9':
    xi = (xi shl 4) or (ord(s[pos]) - ord('0'))
    result = pos+1
  of 'a'..'f':
    xi = (xi shl 4) or (ord(s[pos]) - ord('a') + 10)
    result = pos+1
  of 'A'..'F':
    xi = (xi shl 4) or (ord(s[pos]) - ord('A') + 10)
    result = pos+1
  else: result = pos

proc parseEscape(s: string; w: var string; start: int): int =
  var pos = start + 1
  if pos >= s.len:
    w.add '\\'
    return pos
  case s[pos]
  of 'n', 'N': w.add "\n"; inc pos
  of 'r', 'R', 'c', 'C': w.add '\c'; inc pos
  of 'l', 'L': w.add '\L'; inc pos
  of 'f', 'F': w.add '\f'; inc pos
  of 'e', 'E': w.add '\e'; inc pos
  of 'a', 'A': w.add '\a'; inc pos
  of 'b', 'B': w.add '\b'; inc pos
  of 'v', 'V': w.add '\v'; inc pos
  of 't', 'T': w.add '\t'; inc pos
  of '\'', '"': w.add s[pos]; inc pos
  of '\\': w.add '\\'; inc pos
  of 'x', 'X':
    inc pos
    var xi = 0
    pos = handleHexChar(s, pos, xi)
    pos = handleHexChar(s, pos, xi)
    w.add char(xi and 0xFF)
  of '0'..'9':
    var xi = 0
    while pos < s.len and s[pos] in {'0'..'9'}:
      xi = (xi * 10) + (ord(s[pos]) - ord('0'))
      inc pos
    if xi <= 255: w.add char(xi)
  else:
    w.add '\\'
  result = pos

proc parseWord(s: string; w: var string; start = 0;
               convToLower = false): int =
  template conv(c: char): char =
    (if convToLower: c.toLowerAscii else: c)
  w.setLen 0
  var i = start
  while i < s.len and s[i] in {' ', '\t'}: inc i
  if i >= s.len: return i
  case s[i]
  of '\'':
    inc i
    while i < s.len:
      if s[i] == '\'':
        if i+1 < s.len and s[i+1] == '\'':
          w.add s[i]
          inc i
        else:
          inc i
          break
      else:
        w.add s[i].conv
      inc i
  of '"':
    inc i
    while i < s.len:
      if s[i] == '"':
        inc i
        break
      elif s[i] == '\\':
        i = parseEscape(s, w, i)
      else:
        w.add s[i].conv
        inc i
  else:
    while i < s.len and s[i] > ' ':
      w.add s[i].conv
      inc i
  result = i

proc cmdToArgs(cmd: string): tuple[exe: string, args: seq[string]] =
  result.exe = ""
  result.args = @[]
  var i = parseWord(cmd, result.exe, 0)
  while true:
    var x = ""
    i = parseWord(cmd, x, i)
    if x.len == 0: break
    result.args.add x

# ---------------------------------------------------------------------------
# Background process thread
# ---------------------------------------------------------------------------

var requests: Channel[string]
requests.open()
var responses: Channel[string]
responses.open()

const EndToken = "\e"

proc execThreadProc() {.thread.} =
  var p: Process
  var o: Stream
  var started = false
  while true:
    var tasks = requests.peek()
    if tasks == 0 and not started: tasks = 1
    if tasks > 0:
      for i in 0..<tasks:
        let task = requests.recv()
        if task == EndToken:
          p.terminate()
          o.close()
          started = false
          let exitCode = p.waitForExit()
          p.close()
          if exitCode != 0:
            responses.send("Process terminated with exitcode: " & $exitCode & "\L")
          responses.send EndToken
        else:
          if not started:
            let (bin, args) = cmdToArgs(task)
            try:
              p = startProcess(bin, os.getCurrentDir(), args,
                        options = {poStdErrToStdOut, poUsePath, poInteractive,
                                   poDaemon})
              o = p.outputStream
              started = true
            except:
              started = false
              responses.send getCurrentExceptionMsg()
              responses.send EndToken
          else:
            p.inputStream.writeLine task
    if started:
      if not p.running:
        while not o.atEnd:
          let line = o.readAll()
          responses.send line
        started = false
        let exitCode = p.waitForExit()
        p.close()
        if exitCode != 0:
          responses.send("Process terminated with exitcode: " & $exitCode & "\L")
        responses.send EndToken
      elif osproc.hasData(p):
        let line = o.readAll()
        responses.send line

var backgroundThread: Thread[void]
createThread[void](backgroundThread, execThreadProc)

# ---------------------------------------------------------------------------
# Terminal type
# ---------------------------------------------------------------------------

type
  TermActionKind* = enum
    noAction,
    openFile,           ## user typed `o <file>`
    saveFile,           ## user typed `save`
    ctrlHover,          ## ctrl+mouse move over text
    ctrlClick           ## ctrl+click on text

  TermAction* = object
    case kind*: TermActionKind
    of noAction, saveFile: discard
    of openFile:
      file*: string
    of ctrlHover, ctrlClick:
      pos*: int         ## buffer offset

  Terminal* = object
    ed*: SynEdit
    hist*: Table[string, CmdHistory]
    files: seq[string]
    prefix: string
    processRunning*: bool
    beforeSuggestionPos: int
    aliases*: seq[(string, string)]
    process: string

proc getCommand(t: Terminal): string =
  result = ""
  for i in t.ed.readOnly + 1 ..< t.ed.len:
    result.add t.ed[i]

proc emptyCmd(t: var Terminal) =
  while true:
    if t.ed.len - 1 <= t.ed.readOnly: break
    t.ed.backspace(smartIndent = false)

proc insertPrompt*(t: var Terminal) =
  t.ed.appendOutput(os.getCurrentDir() & ">")

# ---------------------------------------------------------------------------
# Tab completion
# ---------------------------------------------------------------------------

proc startsWithIgnoreCase(s, prefix: string): bool =
  var i = 0
  while true:
    if i >= prefix.len: return true
    if i >= s.len: return false
    if s[i].toLowerAscii != prefix[i].toLowerAscii: return false
    inc i

proc addFile(t: var Terminal; path: string) =
  if find(path, {' ', '\t'}) >= 0:
    t.files.add path.escape
  else:
    t.files.add path

proc suggestPath(t: var Terminal; prefix: string) =
  var sug = -1
  if prefix.len > 0:
    for i, x in t.files:
      if x.extractFilename.startsWithIgnoreCase(prefix) and not x.ignoreFile:
        sug = i
        break
  if sug < 0 and prefix.len > 0:
    let p = prefix.toLowerAscii
    for i, x in t.files:
      if p in x.toLowerAscii and not x.ignoreFile:
        sug = i
        break
  if sug < 0 and prefix.len == 0:
    sug = 0
    while sug < t.files.high:
      if t.files[sug].ignoreFile: inc sug
      else: break
  if sug >=% t.files.len: return
  for i in 0..<t.beforeSuggestionPos:
    t.ed.backspace(smartIndent = false)
  t.ed.insertText(t.files[sug])
  t.beforeSuggestionPos = t.files[sug].len
  delete(t.files, sug)

proc tabPressed(t: var Terminal) =
  if t.ed.changed:
    let cmd = t.getCommand()
    t.prefix.setLen 0
    var prefixB = ""
    var i = 0
    while true:
      i = parseWord(cmd, prefixB, i)
      if prefixB.len == 0:
        if i > 0 and cmd[i-1] == ' ':
          t.prefix.setLen 0
        break
      swap(t.prefix, prefixB)
    t.beforeSuggestionPos = t.prefix.len
    t.files.setLen 0

  if t.files.len == 0:
    let (path, prefix) = t.prefix.splitPath
    if path.len > 0 and path[0] == '~':
      let expandedPath = getHomeDir() / path.substr(1)
      for k, f in os.walkDir(expandedPath, relative = false):
        t.addFile f
    elif t.prefix.isAbsolute:
      for k, f in os.walkDir(path, relative = false):
        t.addFile f
    else:
      for k, f in os.walkDir(os.getCurrentDir() / path, relative = true):
        t.addFile path / f
    t.prefix = prefix
  t.suggestPath(t.prefix)

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

proc dirContents(t: var Terminal; ext: string) =
  var i = 0
  for k, f in os.walkDir(getCurrentDir(), relative = true):
    if ext.len == 0 or cmpPaths(f.splitFile.ext, ext) == 0:
      t.ed.appendOutput(f)
      if i == 4:
        t.ed.appendOutput("\L")
        i = 0
      else:
        t.ed.appendOutput("    ")
      inc i
  t.ed.appendOutput("\L")

proc runCommand*(t: var Terminal; cmd: var string): TermAction =
  result = TermAction(kind: noAction)
  t.files.setLen 0
  t.hist[t.process].addCmd(cmd)
  if t.processRunning:
    requests.send cmd
    return

  var a = ""
  var i = parseWord(cmd, a, 0, true)
  t.ed.appendOutput "\L"
  for al in t.aliases:
    if a == al[0]:
      cmd = al[1] & cmd.substr(i)
      i = parseWord(cmd, a, 0, true)
      break
  case a
  of "":
    t.insertPrompt()
  of "o":
    var b = ""
    i = parseWord(cmd, b, i)
    t.insertPrompt()
    if b.len > 0:
      let path = if isAbsolute(b): b else: os.getCurrentDir() / b
      result = TermAction(kind: openFile, file: path)
  of "save":
    t.insertPrompt()
    result = TermAction(kind: saveFile)
  of "cls":
    t.ed.clear()
    t.ed.lang = langConsole
    t.insertPrompt()
  of "cd":
    var b = ""
    i = parseWord(cmd, b, i)
    try:
      os.setCurrentDir(b)
    except OSError:
      t.ed.appendOutput(getCurrentExceptionMsg() & "\L")
    t.insertPrompt()
  of "d":
    var b = ""
    i = parseWord(cmd, b, i)
    t.dirContents(b)
    t.insertPrompt()
  else:
    if i >= cmd.len - 1 and (a.endsWith".html" or a.startsWith"http://" or
        a.startsWith"https://"):
      openDefaultBrowser(a)
    else:
      requests.send cmd
      t.processRunning = true
      swap(t.process, cmd)
      if t.process notin t.hist:
        t.hist[t.process] = CmdHistory(cmds: @[], suggested: -1)

proc enterPressed(t: var Terminal): TermAction =
  var cmd = t.getCommand()
  result = t.runCommand(cmd)

# ---------------------------------------------------------------------------
# Update (poll background thread)
# ---------------------------------------------------------------------------

proc update*(t: var Terminal) =
  if t.processRunning:
    if responses.peek > 0:
      let resp = responses.recv()
      if resp == EndToken:
        t.processRunning = false
        t.process.setLen 0
        t.ed.appendOutput "\L"
        t.insertPrompt()
      else:
        t.ed.appendOutput(resp)

proc sendBreak*(t: var Terminal) =
  if t.processRunning:
    requests.send EndToken

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

proc createTerminal*(font: Font; theme = catppuccinMocha()): Terminal =
  result = Terminal(
    ed: createSynEdit(font, theme),
    hist: initTable[string, CmdHistory](),
    files: @[],
    prefix: "",
    aliases: @[],
    process: "")
  result.ed.lang = langConsole
  result.hist[""] = CmdHistory(cmds: @[], suggested: -1)
  result.insertPrompt()

# ---------------------------------------------------------------------------
# Drawing (immediate-mode: input + render)
# ---------------------------------------------------------------------------

proc draw*(t: var Terminal; e: Event; area: Rect; focused: bool): TermAction =
  ## Per-frame entry point. When focused, processes input and shows cursor.
  ## When not focused, just paints. Always polls for process output.
  result = TermAction(kind: noAction)
  t.update()

  if focused:
    # Ensure cursor is in the editable area so it's visible.
    if t.ed.cursor <= t.ed.readOnly:
      t.ed.gotoPos(t.ed.len)
    # Intercept terminal-specific keys before passing to SynEdit.
    if e.kind == KeyDownEvent:
      let ctrl = CtrlPressed in e.mods
      case e.key
      of KeyUp:
        if not ctrl:
          let sug = t.hist[t.process].suggest(up = true)
          if sug.len > 0:
            t.emptyCmd()
            t.ed.insertText(sug)
          t.ed.render(area, showCursor = true)
          return
      of KeyDown:
        if not ctrl:
          let sug = t.hist[t.process].suggest(up = false)
          if sug.len > 0:
            t.emptyCmd()
            t.ed.insertText(sug)
          t.ed.render(area, showCursor = true)
          return
      of KeyTab:
        t.tabPressed()
        t.ed.render(area, showCursor = true)
        return
      of KeyEnter:
        result = t.enterPressed()
        t.ed.render(area, showCursor = true)
        return
      of KeyC:
        if ctrl and t.processRunning:
          t.sendBreak()
          t.ed.render(area, showCursor = true)
          return
      else: discard

  let edAct = t.ed.draw(e, area, focused)
  case edAct.kind
  of ctrlHover:
    result = TermAction(kind: ctrlHover, pos: edAct.pos)
  of ctrlClick:
    result = TermAction(kind: ctrlClick, pos: edAct.pos)
  of noAction: discard
