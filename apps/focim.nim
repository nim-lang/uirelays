##[
focim -- the Focussed Nim Editor.

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
  "open file" dialog. Under `..` are the two places one keeps wanting to get
  back to: `[Editor]` for the directory of the file in the editor,
  `[Terminal]` for the one the terminal is in.

The same idea applied to the window itself: tab 0 is `[config]`, and its text
IS the NIF `(config ...)` this app is built from -- the `(layout ...)` that
places the widgets and the `(theme ...)` that colors them. Editing it
relayouts and recolors the window on the next frame, so there is no separate
settings dialog either. Leaving a widget out of the layout hides it without
destroying it -- its buffer, cursor and scroll position are still there when a
later layout lists it again. Only the `editor` cell has to stay, since it is
where the config gets typed. A config that does not parse is reported in the
status bar, with the line and column of the mistake, and ignored, so the last
good one keeps the window usable; a theme whose text would be unreadable on
its own background is refused the same way. Every color in it is written as
`"#RRGGBB"`, which SynEdit draws a chip of, so the palette is visible while it
is being edited.

The config and the list of open tabs are stored under `getConfigDir()` in
`focim/config.nif` and `focim/tabs.txt`, so both survive a restart.

Markdown is still SynEdit, not a browser pane. Headings, links and fenced
code light up in place; Cmd/Ctrl+click on a `[label](path)` opens a relative
file (or jumps to `#heading`), so Nimony's `doc/*.md` can be explored without
leaving the editor.

Ctrl+Space completes a word. There is no compiler in the loop and nothing
here knows what a name *means*; what it knows is which names exist -- in the
open buffers, in a directory that `index <path>` was pointed at, and in the
Nimony vocabulary that ships with the editor. See `doc/completion.md`.
]##

import std/[tables, os, algorithm]
from std/strutils import toLowerAscii, strip, endsWith, contains, splitLines,
                         startsWith, find
from std/cmdline import paramCount, paramStr
import uirelays
import uirelays/layout
import widgets/[synedit, terminal, config, wordindex]
import completion

const defaultConfig = """
(config
  (layout
    (cols
      (rows (px 200)
        (tabs (lines 6))
        (explorer))
      (editor (stretch 4))
      (rows (stretch 2)
        (history (lines 5))
        (terminal)))
    (status (lines 1)))
  # Anything left out keeps the color it has; `doc/config.md` lists the fields.
  # Every token class is written out below, so any of them can be recolored by
  # editing the line rather than by first finding out that the class exists.
  # A color may be followed by (bold), by (italics), or by both.
  (theme
    (bg "#15171B")
    (fg "#E6DFD1"                     # the base color, for anything unnamed
      (None "#E6DFD1")
      (Whitespace "#E6DFD1")
      (DecNumber "#E8833A")
      (BinNumber "#E8833A")
      (HexNumber "#E8833A")
      (OctNumber "#E8833A")
      (FloatNumber "#E8833A")
      (Identifier "#E6DFD1")
      (Keyword "#E5B94E" (bold))
      (StringLit "#2EC4B6")
      (LongStringLit "#2EC4B6")
      (CharLit "#2EC4B6")
      (Backticks "#2EC4B6")
      (EscapeSequence "#F2A65A")
      (Operator "#C9A227")
      (Punctuation "#8C8578")
      (Comment "#7A7365" (italics))
      (LongComment "#7A7365" (italics))
      (RegularExpression "#E8833A")
      (TagStart "#E5B94E")            # markup
      (TagStandalone "#E5B94E")
      (TagEnd "#E5B94E")
      (Key "#2EC4B6")                 # ini, nif, config files
      (Value "#E8833A")
      (RawData "#2EC4B6")
      (Assembler "#E5B94E")
      (Preprocessor "#1FA398")
      (Directive "#1FA398")
      (Command "#E5B94E")
      (Rule "#1FA398")
      (Link "#4FD1C5")
      (Label "#E8833A")
      (Reference "#E8833A")
      (Text "#E6DFD1")
      (Other "#E6DFD1")
      (Green "#4FBF9F")               # the three the terminal colors by name
      (Yellow "#E5B94E")
      (Red "#E4634A")
      (MarkdownFence "#7A7365"))))
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
  ConfigDirName = "focim"
  WordsDirName = "words"
    ## Under the config dir: one file per indexed path, so that `index` is
    ## paid for once and not on every start.
  ShippedWords = "nimony.txt"
    ## The vocabulary that comes with the editor, next to the binary.

proc configPath(name: string): string =
  getConfigDir() / ConfigDirName / name

proc saveConfig(name, text: string) =
  ## Best effort: an unwritable config dir must not take the editor down.
  try:
    createDir(configPath(name).parentDir)
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
    isConfig: bool      ## this buffer's text IS the window's config
    idx: BufferIndexer  ## how far the word index has walked this buffer

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
      if b.isConfig: "[config]"
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
      if buffers[i].isConfig:
        # Closing it would leave no way to edit the config back.
        tabs.note = "the config buffer stays open"
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

proc reparseConfig(src: string; width, height, lineHeight: int;
                   layout: var Layout; theme: var Theme; note: var string) =
  ## The config buffer's text IS the window. A config that does not parse, or
  ## that loses a cell the app needs, is reported and dropped -- the last good
  ## one keeps the window usable so the text can be corrected. A theme that
  ## cannot be read is dropped by the parser in the same spirit, and says so in
  ## `note` while the rest of the config is kept.
  let parsed = parseConfig(src)
  if parsed.error.len > 0:
    note = "config: " & parsed.error
    return
  let cells = parsed.layout.resolve(width, height, lineHeight, gap = 2)
  for name in RequiredCells:
    if name notin cells:
      note = "config: no '" & name & "' cell"
      return
  layout = parsed.layout
  theme = parsed.theme
  note = parsed.note

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

const NavEntries = ["..", "[Editor]", "[Terminal]"]
  ## The lines every unfiltered listing starts with, before the directory
  ## itself: up one level, the directory of the file in the editor, and the
  ## directory the terminal is in -- the two places one keeps wanting to get
  ## back to once the listing has wandered off somewhere else. The brackets
  ## are the tell that these are not entries of this directory; no file is
  ## named like that, and the position decides anyway.

proc listDir(dir, filter: string): seq[string] =
  ## The navigation lines first, then directories, then files. Dotfiles are
  ## hidden.
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
  # Filtering is a search through this directory, and the navigation lines are
  # not part of it -- they would survive every filter and be in the way of the
  # first match, which is what Enter takes.
  if filter.len == 0:
    for n in NavEntries: result.add n
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

proc navShown(ex: Explorer): bool =
  ## Are the navigation lines in the listing? ".." gives it away: a filtered
  ## listing never contains it. Asking this instead of comparing the line's
  ## text means a real file could be called "[Editor]" and would still open --
  ## it is a different line, further down, and only the position decides.
  ex.entries.len >= NavEntries.len and ex.entries[0] == NavEntries[0]

proc activateEntry(ex: var Explorer; idx: int;
                   buffers: var seq[BufferEntry]; current: var int;
                   font: Font; focus: var string;
                   termDir: string; note: var string) =
  if idx < 0 or idx >= ex.entries.len: return
  if ex.navShown and idx < NavEntries.len:
    case idx
    of 0:
      let up = ex.dir.parentDir
      if up.len > 0: ex.showDir(up)
    of 1:
      # The file in the editor, not the tab list's idea of it: an unsaved
      # buffer has no directory to go to and says so rather than jumping
      # somewhere plausible.
      let p = buffers[current].path
      if p.len > 0: ex.showDir(p.parentDir)
      else: note = "this buffer has no file yet"
    else:
      if termDir.len > 0 and dirExists(termDir): ex.showDir(termDir)
      else: note = "the terminal is in " & termDir & ", which is gone"
    return
  let name = ex.entries[idx]
  if name.endsWith($DirSep):
    ex.showDir(ex.dir / name[0 ..< name.len - 1])
  else:
    let p = ex.dir / name
    if fileExists(p):
      current = buffers.openFile(font, p, -1, -1)
      setWindowTitle("focim - " & name)
      focus = "editor"

# ---------------------------------------------------------------------------
# Word sets on disk
# ---------------------------------------------------------------------------

proc wordSetFile(name: string): string =
  ## A path is not a file name, so every separator becomes an underscore.
  ## Two paths could in principle collide here; the file says which one it
  ## holds, so the worst case is that a cache is rewritten.
  var s = ""
  for c in name:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.'}: s.add c
    elif s.len > 0 and s[^1] != '_': s.add '_'
  result = WordsDirName / s.strip(chars = {'_'}) & ".txt"

proc loadWordSet(words: var WordIndex; file: string) =
  ## Best effort, like everything else that reads a file the editor wrote: a
  ## word list is a cache, and a cache that is gone or unreadable is a reason
  ## to have fewer words, never a reason to stop.
  var text = ""
  try:
    text = readFile(file)
  except CatchableError:
    return
  var ws = parseWordSet(text)
  if ws.name.len == 0: ws.name = file
  words.addSet ws

proc loadWordSets(words: var WordIndex) =
  ## The shipped vocabulary, then everything `index` stored in earlier runs.
  for p in [getAppDir() / "data" / ShippedWords,
            getAppDir().parentDir / "data" / ShippedWords]:
    if fileExists(p):
      loadWordSet(words, p)
      break
  try:
    for kind, p in walkDir(configPath(WordsDirName)):
      if kind == pcFile and p.endsWith(".txt"):
        loadWordSet(words, p)
  except CatchableError:
    discard

proc runIndexCommand(act: TermAction; words: var WordIndex; job: var IndexJob;
                     note: var string) =
  ## `index` on its own says what is indexed, `index <path>` starts a job, and
  ## `unindex <path>` forgets one.
  if act.path.len == 0:
    var s = $words.wordCount & " words, " & $words.liveCount & " of them from " &
            "the open buffers"
    for ws in words.sets: s.add "; " & ws.name & " " & $ws.words.len
    note = s
  elif act.forget:
    if words.dropSet(act.path):
      try: removeFile(configPath(wordSetFile(act.path)))
      except CatchableError: discard
      note = "forgot " & act.path
    else:
      note = "not indexed: " & act.path
  elif not fileExists(act.path) and not dirExists(act.path):
    note = "no such path: " & act.path
  else:
    job = startIndexJob(act.path)
    if job.active: note = job.progress
    else: note = "nothing to index in " & act.path

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
    setWindowTitle("focim - " & path)
    term.ed.appendOutput("\L")
    term.insertPrompt()
    var lsCmd = "ls"
    discard term.runCommand(lsCmd)
  elif fileExists(path):
    current = buffers.openFile(font, path, ln, fc)
    setWindowTitle("focim - " & path.extractFilename)
    focus = "editor"

proc splitMarkdownTarget(url: string): tuple[path, frag: string] =
  ## Split `path#heading` / `#heading` into path and fragment.
  let hash = url.find('#')
  if hash < 0: return (url, "")
  if hash == 0: return ("", url[1 .. ^1])
  result = (url[0 ..< hash], url[hash + 1 .. ^1])

proc isExternalUrl(url: string): bool =
  let u = url.toLowerAscii
  u.startsWith("http://") or u.startsWith("https://") or u.startsWith("mailto:")

proc markdownLinkAt(ed: SynEdit; pos: int): tuple[url: string; a, b: int] =
  ## Prefer a real markdown link; fall back to a bare path under the cursor.
  result = ed.extractMarkdownLink(pos)
  if result.a >= 0: return
  let (path, a, b) = ed.extractPath(pos)
  if path.len > 0: result = (path, a, b)

proc handleMarkdownCtrlClick(ed: var SynEdit; pos: int;
                             buffers: var seq[BufferEntry]; current: var int;
                             font: Font; focus: var string;
                             note: var string; explorer: var Explorer) =
  ## Follow a markdown link from the focused editor buffer.
  let (url, a, b) = ed.markdownLinkAt(pos)
  if url.len == 0: return
  ed.underline(a, b)
  let (path, frag) = splitMarkdownTarget(url)
  if path.len == 0:
    if not ed.gotoMarkdownHeading(frag):
      note = "no heading: #" & frag
    return
  if isExternalUrl(path):
    note = "external: " & path
    return
  let base =
    if buffers[current].path.len > 0: buffers[current].path.parentDir
    else: os.getCurrentDir()
  let full = if isAbsolute(path): path else: base / path
  if fileExists(full):
    current = buffers.openFile(font, full, -1, -1)
    setWindowTitle("focim - " & full.extractFilename)
    focus = "editor"
    note = ""
    if frag.len > 0 and not buffers[current].ed.gotoMarkdownHeading(frag):
      note = "opened, but no heading: #" & frag
  elif dirExists(full):
    explorer.showDir(full)
    focus = "explorer"
    note = ""
  else:
    note = "not found: " & full

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
    setWindowTitle("focim - " & path.extractFilename)
    focus = "editor"
  elif dirExists(path):
    os.setCurrentDir(path)
    setWindowTitle("focim - " & path)

proc adjustFocusedFontSize(
    focus: string; delta: int;
    fonts: var Table[int, Font];
    history: var SynEdit;
    tabs: var TabList; explorer: var Explorer;
    term, status: var Terminal;
    buffers: var seq[BufferEntry]; current: int;
    panelFontSize, historyFontSize,
    terminalFontSize, statusFontSize, editorFontSize: var int) =
  case focus
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
  # An editor wants the whole desktop, so ask for it -- as a window, not as
  # `fullScreen`: the menu bar and the other windows stay reachable, which
  # matters for an app whose terminal is meant to be used next to a browser.
  let screen = createWindow(MaxWindowWidth, MaxWindowHeight)
  var width = screen.width
  var height = screen.height
  gUiScale = screen.uiScale

  var fonts: Table[int, Font]
  let font = fonts.fontForSize(DefaultFontSize)
  var fm = getFontMetrics(font)
  setWindowTitle("focim")

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
  var panelFontSize = DefaultFontSize
  var historyFontSize = DefaultFontSize
  var terminalFontSize = DefaultFontSize
  var statusFontSize = DefaultFontSize
  var editorFontSize = DefaultFontSize

  # The config the window starts with: whatever was stored last time, unless it
  # no longer works -- then the default, with the reason in the status bar.
  var layout = default(Layout)
  var theme = defaultTheme()
  var configNote = ""
  reparseConfig(defaultConfig, width, height, fm.lineHeight, layout, theme,
                configNote)
  doAssert configNote.len == 0, configNote
  var configText = loadConfig("config.nif")
  if configText.len > 0:
    reparseConfig(configText, width, height, fm.lineHeight, layout, theme,
                  configNote)
    if configNote.len > 0:
      # Whatever was wrong with it, the stored text stays in the buffer: it is
      # what has to be corrected. Until it parses the window runs on the
      # default, which the call above left in place.
      configNote = configPath("config.nif") & ": " & configNote
  else:
    configText = defaultConfig

  # Buffer list. The config buffer is tab 0: editing it relayouts and recolors
  # the window on the next frame. The rest of the tabs are last session's.
  var buffers: seq[BufferEntry]
  var current = 0
  block:
    var ed = createSynEdit(fonts.fontForSize(editorFontSize))
    # NIF is close enough to Nim for the tokenizer: parentheses, names, numbers
    # and '#' comments all land where they should -- and a quoted "#RRGGBB" is
    # a string literal, which is what makes `rfColorLiterals` draw a chip of
    # the color right beside it.
    ed.lang = langNim
    ed.flags = {rfColorLiterals}
    ed.showLineNumbers = true
    ed.setText(configText)
    buffers.add BufferEntry(ed: ed, path: "", isConfig: true)
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
  # Where the pointer was last seen. A wheel event carries its delta in `x`
  # and `y` and nothing about where it happened, so this is what says which
  # panel the wheel is over.
  var pointerX, pointerY = -1

  # The words Ctrl+Space can offer: the shipped Nimony vocabulary, whatever
  # `index` was pointed at in an earlier run, and -- from here on, a slice per
  # frame -- everything in the open buffers.
  var words = WordIndex()
  loadWordSets(words)
  var job = IndexJob()
  var comp = initCompletion(fonts.fontForSize(editorFontSize))

  var running = true
  while running:
    # Pick up edits to the config buffer before resolving, so that the rects
    # and the hit tests within one frame always come from the same layout.
    # The buffer's own changed flag is the signal; consuming it here re-parses
    # once per edit, whether the new config works out or not.
    for b in buffers.mitems:
      if b.isConfig and b.ed.changed:
        let src = b.ed.fullText
        reparseConfig(src, width, height, fm.lineHeight, layout, theme,
                      configNote)
        if configNote.len == 0: saveConfig("config.nif", src)
        b.ed.markSaved()

    # The theme goes out to every widget every frame. Buffers come and go and
    # the colors can change with any keystroke in the config, so there is no
    # single place to hook this that could not be forgotten later.
    history.theme = theme
    tabs.ed.theme = theme
    explorer.ed.theme = theme
    term.ed.theme = theme
    status.ed.theme = theme
    comp.theme = theme
    comp.setFont buffers[current].ed.getFont
    for b in buffers.mitems: b.ed.theme = theme

    # The word index, a slice of one buffer per frame: whichever buffer the
    # last edit left behind is caught up on before any other work, and none of
    # it is ever felt because none of it is ever more than a couple hundred
    # lines. `index` jobs run the same way, a few files at a time.
    for i in 0 ..< buffers.len:
      if buffers[i].idx.needsIndexing(buffers[i].ed):
        discard words.indexSlice(buffers[i].ed, buffers[i].idx)
        break
    if job.active:
      stepIndexJob(job, files = 32)
      if job.active:
        tabs.note = job.progress
      else:
        let ws = doneIndexJob(job)
        words.addSet ws
        saveConfig(wordSetFile(ws.name), ws.toText)
        tabs.note = "indexed " & ws.name & ": " & $ws.words.len & " words" &
          (if job.skipped > 0: ", " & $job.skipped & " files unreadable" else: "") &
          (if job.truncated: ", stopped at " & $MaxIndexFiles & " files" else: "")
        job = IndexJob()

    let cells = layout.resolve(width, height, fm.lineHeight, gap = 2)
    # A layout may have dropped the cell that had the focus.
    if focus notin cells: focus = "editor"

    # Fill background -- gaps between cells show this color as borders, so it
    # comes from the theme: `actionColor` is what the theme already uses to
    # frame things.
    fillRect(rect(0, 0, width, height), theme.actionColor)

    var e = default Event
    # An index job is the one thing here that has work of its own to do: while
    # one runs the loop only polls, so the job gets every frame instead of one
    # every half second.
    discard waitEvent(e, if job.active: 0 else: 500, {WantTextInput})
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
    of MouseMoveEvent:
      pointerX = e.x
      pointerY = e.y
    of MouseWheelEvent:
      # The wheel turns whatever it is pointing at, focused or not -- reaching
      # for the wheel is not a decision to type there. The event is consumed,
      # so the focused panel does not scroll along with the one under the
      # pointer.
      case cells.hitTest(pointerX, pointerY).name
      of "editor": buffers[current].ed.wheelScroll(e.y)
      of "tabs": tabs.ed.wheelScroll(e.y)
      of "explorer": explorer.ed.wheelScroll(e.y)
      of "history": history.wheelScroll(e.y)
      of "terminal": term.ed.wheelScroll(e.y)
      of "status": status.ed.wheelScroll(e.y)
      else: discard
      e = default Event
    of MouseDownEvent:
      pointerX = e.x
      pointerY = e.y
      comp.dismiss()
      let hit = cells.hitTest(e.x, e.y)
      if hit.name.len > 0:
        focus = hit.name
    of TextInputEvent:
      # Ctrl+Space is a command, not a space. X11 hands the app both, and the
      # space would land in the buffer right where the completion is about to
      # go; the key event above has already been dealt with.
      if CtrlPressed in e.mods and e.text[0] == ' ' and e.text[1] == '\0':
        e = default Event
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
        adjustFocusedFontSize(focus, delta, fonts, history,
                              tabs, explorer, term, status, buffers, current,
                              panelFontSize, historyFontSize,
                              terminalFontSize, statusFontSize, editorFontSize)
        e = default Event  # consume the event
      elif cmd and e.key == KeySpace and focus == "editor":
        comp.show(words, buffers[current].ed)
        if not comp.active:
          tabs.note = if comp.prefix.len > 0:
                        "no word starts with '" & comp.prefix & "'"
                      else: "no words indexed yet"
        e = default Event  # consume the event
      elif focus == "editor" and comp.handleKey(e, buffers[current].ed):
        # While the listing is up a few keys belong to it. Everything else --
        # letters, backspace, the arrows sideways -- goes to the editor as
        # usual and narrows the listing through the prefix.
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
            setWindowTitle("focim - " & full.extractFilename)
            focus = "editor"
          elif explorer.entries.len > 0:
            # A partial name accepts the first match.
            explorer.activateEntry(0, buffers, current,
                                   fonts.fontForSize(editorFontSize), focus,
                                   term.cwd, tabs.note)
        elif line - 1 < explorer.entries.len:
          explorer.activateEntry(line - 1, buffers, current,
                                 fonts.fontForSize(editorFontSize), focus,
                                 term.cwd, tabs.note)
        e = default Event
    else: discard

    # Widgets the layout leaves out are simply not drawn. They keep their
    # state, so they come back exactly as they were once a layout lists
    # them again.

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
            explorer.activateEntry(line - 1, buffers, current,
                                   fonts.fontForSize(editorFontSize), focus,
                                   term.cwd, tabs.note)
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
      if buffers[current].ed.lang == langMarkdown:
        handleMarkdownCtrlClick(buffers[current].ed, edAct.pos, buffers,
                                current, fonts.fontForSize(editorFontSize),
                                focus, tabs.note, explorer)
      # else: language server lookup at edAct.pos
    of ctrlHover:
      if buffers[current].ed.lang == langMarkdown:
        let (_, a, b) = buffers[current].ed.markdownLinkAt(edAct.pos)
        buffers[current].ed.underline(a, b)
      # else: underline identifier at edAct.pos
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
        setWindowTitle("focim - " & termAct.file.extractFilename)
        focus = "editor"
    of saveFile:
      if buffers[current].path.len > 0:
        buffers[current].ed.saveToFile(buffers[current].path)
    of indexWords:
      runIndexCommand(termAct, words, job, tabs.note)
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
    # A broken config is the more urgent of the two notes: it is what the
    # user is looking at while typing in the [config] tab.
    let note = if configNote.len > 0: configNote else: tabs.note
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
    of indexWords:
      runIndexCommand(statusAct, words, job, tabs.note)
    of ctrlHover, ctrlClick, noAction: discard

    # The completion listing, last: it goes over everything, and it can only
    # be placed once the editor has drawn the caret it hangs from.
    comp.draw(words, buffers[current].ed, cells["editor"], focus == "editor")

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
