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

Both the terminal and the status bar take commands, and some of them act on the
buffer rather than on the machine: `o <file>` / `open <file>` opens one, `s` /
`save` writes the current one back, `s <file>` writes it somewhere else. A
relative path means what it would mean where it was typed: in the terminal,
relative to the directory the terminal is in; on the prompt, relative to the
file being edited. A name that is not found as written is looked for in the
directory of every open tab, then as an abbreviation of a file in one of them,
and then in the *project* those directories are in -- so `o synedit` finds
`src/widgets/synedit.nim`, and `o xelim.nim` finds `src/hexer/xelim.nim` with
nothing but `nimony/README.md` open. See `doc/focim/open.md`. Ctrl+P is
`open ` already typed into the prompt, for the muscle memory other editors
have trained.

`defaults`, in the prompt, puts the config the app ships with back into the
`[config]` tab -- for a config that has been edited into a corner: a flattened
palette, a layout with the panel one is looking for left out of it. It is an
edit like any other, so `Ctrl+Z` in that tab brings the old config back. Only
the prompt understands the word; in the terminal it names a program, which is
what the terminal is for.

`find`, `findall`, `next`, `prev`, `replace` and `replaceall` are the same idea
applied to searching: no dialog, one line of text, and every match highlighted
in place -- in the other open tabs as well. Ctrl+F, F3 and Shift+F3 are there
for the fingers that expect them. See `doc/focim/search.md`.

A command that has to ask something -- overwriting a file, replacing a match --
puts the question in the status bar and moves the caret there: the next line
typed *in the prompt* is the answer to it rather than a command. The terminal
is never asked anything, because it is where programs run and `yes` is one of
them. Both are the same SynEdit-backed `Terminal` widget; what makes one of
them a prompt is that the app points its `baseDir` at the current tab and lets
it carry a `question`.

What a terminal prints is highlighted too, by the console highlighter ported
from NimEdit: `Error:`, `Warning:` and `Hint:` take the three named colors, a
`[Tag]` behind a compiler message reads as one, and a diff is colored by the
first character of each line -- so `git diff` comes out in red and green with
its hunk headers picked out, without anything in the pipe emitting an escape
sequence.

What it printed is protected from editing, not from being read. The caret goes
up into the output, the arrow keys and the mouse move through it, and a
selection can be taken out of it exactly as in the editor. What brings the
caret back down is a key that edits -- a character, a paste, Tab, Enter -- so
those always land on the command line wherever the caret was left standing. Up
and Down are the command history while the caret is on that line and ordinary
caret keys above it; Ctrl+C copies while something is selected and stops the
running program when nothing is. A program that prints while its output is
being read leaves both the caret and the scroll position alone.

The config and the list of open tabs are stored under `getConfigDir()` in
`focim/config.nif` and `focim/tabs.txt`, so both survive a restart.

Markdown is still SynEdit, not a browser pane. Headings, links and fenced
code light up in place; Cmd/Ctrl+click on a `[label](path)` opens a relative
file (or jumps to `#heading`), so Nimony's `doc/*.md` can be explored without
leaving the editor.

Ctrl+Space completes a word. There is no compiler in the loop and nothing
here knows what a name *means*; what it knows is which names exist -- in the
open buffers, in a directory that `index <path>` was pointed at, and in the
Nimony vocabulary that ships with the editor. See `doc/focim/completion.md`.

Ctrl+click on a name in a `.nim` file is the one place a compiler *is* in the
loop: `nim track` (or nimony) is asked where the name is declared and where it
is used, and the answer comes back as the same listing Ctrl+Space uses -- one
row per place, Enter to go there. The compiler runs in a thread, so the window
stays a window while it thinks. `(track (compiler "nim"))` in the config says
which compiler, and `"none"` says nobody. See `doc/focim/track.md`.

The `clipboard` cell keeps what the clipboard held. A system clipboard holds
one thing, so copying twice before pasting once loses the first -- here the
last thirty texts that entered it stay, from this application or from any
other, numbered, and Ctrl+1 .. Ctrl+9 paste one at the caret. See
`doc/focim/clipboard.md`.

Icon: `focim-icon.png` is the source art, and the files built from it that are
checked in next to it -- `focim-icon.netwm` for X11, `focim.ico` / `.rc` /
`.res` for Windows. Deriving those from the PNG, and installing the desktop
entry or the `.app` bundle, is somebody else's job: `iconbundler`
(https://github.com/Araq/iconbundler), which is a tool for any desktop
application and does not belong in a UI library. After changing the PNG, from
`apps/`:

    iconbundler --prepare focim

and to install this build for the desktop as well:

    iconbundler focim ../focim focim-icon.png \
      --generic-name "Text Editor" --comment "Focussed Nim Editor" \
      --categories "Development;TextEditor;"

`StartupWMClass` / the bundle id stem must match the name of the executable,
which is what lands in `WM_CLASS` -- so the binary has to stay called `focim`.
]##

import std/[tables, os, algorithm]
from std/strutils import toLowerAscii, strip, endsWith, contains, splitLines,
                         startsWith, find
from std/cmdline import paramCount, paramStr
import uirelays
import uirelays/layout
import widgets/[synedit, terminal, config, wordindex, cliphistory, search,
                filesearch]
import focim/track
import completion

# Derived from focim-icon.png by `iconbundler --prepare focim`.
when defined(windows):
  {.link: "focim.res".}

when defined(linux):
  const focimIconNetWm = staticRead("focim-icon.netwm")

  proc focimIcon(): seq[uint32] =
    ## The blob as the CARDINALs `createWindow` puts on the window.
    var raw = focimIconNetWm
    let n = raw.len div 4
    result = newSeq[uint32](n)
    if n > 0:
      copyMem(addr result[0], addr raw[0], n * 4)
else:
  proc focimIcon(): seq[uint32] = @[]
    ## Windows takes its icon from the linked `.res` and macOS from the bundle,
    ## so there is nothing for the window itself to carry.

const defaultConfig = """
(config
  (layout
    (cols
      (rows (px 200)
        (tabs (lines 6))
        (explorer))
      (editor (stretch 4))
      (rows (stretch 2)
        (clipboard (lines 9))
        (history (lines 5))
        (terminal)))
    (status (lines 1)))
  # Anything left out keeps the color it has; `doc/focim/config.md` lists
  # the fields.
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
      (MarkdownFence "#7A7365")))
  # Who answers a Ctrl+click on a name: "nim", "nimony", or "none" for nobody.
  # (exe "...") names the binary when it is not simply on the PATH.
  (track
    (compiler "nim")))
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
  MaxPreviewChars = 60
    ## How much of a line a tracking row quotes. A row is a thing to recognize
    ## a place by, not a place to read the code in.
  MaxPreviewBytes = 4_000_000
    ## Above this a file is not read for a one-line quote. Nothing anyone wrote
    ## by hand is that big, and the row is worth less than the pause would be.

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

proc scaledPx(value: int): int {.inline.} =
  ## The same turn from logical to physical that `fontForSize` does for a font
  ## size, for the handful of pixel sizes this file states itself. The `(px N)`
  ## sizes in a layout are `resolve`'s business, not this one's.
  value * gUiScale div 100

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
    search: BufferSearch ## the hits of the last search in this buffer

proc applyFileKind(ed: var SynEdit; path: string) =
  ## What the name of a file says about how to show it. Runs when a buffer is
  ## created and again after a `save <other-name>`: a buffer that just became a
  ## `.md` is a markdown buffer from then on.
  let ext = path.splitFile.ext.toLowerAscii
  ed.setLanguage fileExtToLanguage(ext)
  ed.flags = {rfColorLiterals}
  if ext == ".md" or ext == ".markdown":
    ed.flags.incl rfMarkdownImages

proc newBuffer(font: Font; path: string): BufferEntry =
  var ed = createSynEdit(font)
  ed.showLineNumbers = true
  ed.applyFileKind(path)
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
  ## Active and modified state as colors, not as text. Offsets are derived
  ## from the names because the text is exactly `names` joined by newlines.
  let theme = tabs.ed.theme
  tabs.ed.clearMarkers()
  # The active tab takes the whole row, the same band the editor draws behind
  # the line the caret is on -- a tab is the row, not the word in it, and a
  # highlight that stops after the name makes the list look ragged instead of
  # making one line of it stand out.
  tabs.ed.setRowHighlight(current, theme.activeLineBg)
  # The modified mark stays a marker: it belongs to the name, and on the
  # active tab it has to be visible *on* the band rather than instead of it.
  var pos = 0
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
                   layout: var Layout; theme: var Theme; track: var Track;
                   note: var string) =
  ## The config buffer's text IS the window. A config that does not parse, or
  ## that loses a cell the app needs, is reported and dropped -- the last good
  ## one keeps the window usable so the text can be corrected. A theme that
  ## cannot be read is dropped by the parser in the same spirit, and says so in
  ## `note` while the rest of the config is kept.
  let parsed = parseConfig(src)
  if parsed.error.len > 0:
    note = "config: " & parsed.error
    return
  let cells = parsed.layout.resolve(width, height, lineHeight,
                                    padding = scaledPx(6), gap = scaledPx(4),
                                    uiScale = gUiScale)
  for name in RequiredCells:
    if name notin cells:
      note = "config: no '" & name & "' cell"
      return
  layout = parsed.layout
  theme = parsed.theme
  track = parsed.track
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
  ## listed too; a hidden file one cannot see is a file one cannot open.
  var dirs: seq[string] = @[]
  var files: seq[string] = @[]
  let f = filter.toLowerAscii
  for kind, path in walkDir(dir):
    let name = path.extractFilename
    if name.len == 0: continue
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
  let path = if isAbsolute(file): file else: term.base / file
  term.ed.underline(a, b)
  if dirExists(path):
    # The terminal's own idea of where it is -- the same thing `cd` moves, and
    # what the next command is run in. It does not go in the window title: the
    # title says which buffer is being edited, and a directory there would be
    # a second meaning that stays until the buffer happens to change. The
    # prompt already says where the terminal is.
    term.cwd = path
    term.ed.appendOutput("\L")
    term.insertPrompt()
    var lsCmd = "ls"
    discard term.runCommand(lsCmd)
  elif fileExists(path):
    current = buffers.openFile(font, path, ln, fc)
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

# ---------------------------------------------------------------------------
# Tracking -- where a name is declared and where it is used, per the compiler
# ---------------------------------------------------------------------------

proc startTrack(tracker: var Tracker; spec: Track; ed: var SynEdit; pos: int;
                path: string; note: var string) =
  ## What a Ctrl+click on a name in a `.nim` buffer asks for. The click has
  ## already put the caret in the name; the *start* of the name is what gets
  ## asked about, so that clicking anywhere in it is the same question.
  let (word, a, b) = ed.wordAt(pos)
  if word.len == 0:
    note = "nothing to look up here"
    return
  ed.underline(a, b)
  let (line, col) = ed.lineAndByteCol(a)
  discard tracker.start(spec, path, line, col, word)
  note = tracker.note

proc shortPath(path, base: string): string =
  ## What a row calls a file. Inside the project it is the path from the
  ## project down, which is how one talks about one's own files; outside it --
  ## the standard library, another package -- the last directory and the name,
  ## since the absolute path would be the widest thing in the listing and the
  ## least worth reading.
  if base.len > 0 and path.len > base.len and path.startsWith(base) and
     path[base.len] == DirSep:
    result = path[base.len + 1 .. ^1]
  else:
    let parent = path.parentDir.lastPathPart
    result = if parent.len > 0: parent & "/" & path.extractFilename
             else: path.extractFilename

proc sourceLine(path: string; line: int; buffers: seq[BufferEntry];
                cache: var Table[string, seq[string]]): string =
  ## Line `line` of `path`, for the row that offers to go there. An open buffer
  ## answers first: it is what the file *is* right now, and an unsaved edit is
  ## exactly the case where the text on disk would be misleading. Everything
  ## else is read once per file, however many rows point into it.
  for b in buffers:
    if b.path == path and not b.isConfig:
      return b.ed.getLineText(line - 1).strip
  if path notin cache:
    var lines: seq[string] = @[]
    try:
      if getFileSize(path) <= MaxPreviewBytes:
        lines = readFile(path).splitLines
    except CatchableError:
      discard
    cache[path] = lines
  let lines = cache[path]
  result = if line >= 1 and line <= lines.len: lines[line - 1].strip else: ""

proc trackRows(hits: seq[TrackHit]; base: string;
               buffers: seq[BufferEntry]): seq[string] =
  ## One row per place: what it is, where it is, and what stands there. The
  ## `where` column is padded to a common width so that the source text lines
  ## up and the eye can run down it.
  var cache = initTable[string, seq[string]]()
  var where: seq[string] = @[]
  var widest = 0
  for h in hits:
    let w = (if h.isDef: "def " else: "use ") & shortPath(h.path, base) &
            ":" & $h.line
    where.add w
    widest = max(widest, w.len)
  result = @[]
  for i, h in hits:
    var row = where[i]
    while row.len < widest: row.add ' '
    let src = sourceLine(h.path, h.line, buffers, cache)
    if src.len > 0:
      row.add "  "
      row.add(if src.len > MaxPreviewChars: src[0 ..< MaxPreviewChars] & "..."
              else: src)
    result.add row

proc jumpTo(hit: TrackHit; buffers: var seq[BufferEntry]; current: var int;
            font: Font; focus: var string; note: var string) =
  ## Go where a row points. The answer is as old as the query that produced it,
  ## so the file may be gone by now -- which is a note, not a crash.
  if not fileExists(hit.path):
    note = "gone since the compiler saw it: " & hit.path
    return
  current = buffers.openFile(font, hit.path, -1, -1)
  buffers[current].ed.gotoLineBytes(hit.line, hit.col)
  focus = "editor"
  note = ""

proc updateStatus(status: var Terminal; ed: SynEdit; path, note: string) =
  let name = if path.len > 0: path.extractFilename else: "[scratch]"
  let info = name & "  Ln " & $(ed.currentLine + 1) &
             ", Col " & $(ed.currentCol + 1) &
             (if ed.changed: "  *" else: "") &
             (if note.len > 0: "  " & note else: "") & " > "
  status.ed.clear()
  status.ed.lang = langConsole
  status.ed.appendOutput(info)

proc prepareCommand(status: var Terminal; buffers: seq[BufferEntry];
                    current: int; cmd, note: string) =
  ## Leave the prompt as if `cmd` had just been typed into it. `updateStatus`
  ## rewrites the line on every frame the status bar is *not* focused, so this
  ## is only ever a keystroke away from being undone -- the caller moves the
  ## focus there.
  updateStatus(status, buffers[current].ed, buffers[current].path, note)
  status.ed.insertText(cmd)

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

# ---------------------------------------------------------------------------
# `o` and `save` -- the two commands that act on the buffer rather than on the
# machine. Both are typed in a Terminal (the status prompt or the terminal
# itself), and both take a path that is relative to whatever that widget
# considers current: the directory of the file being edited for the prompt,
# the directory the terminal is in for the terminal.
# ---------------------------------------------------------------------------

proc searchDirs(buffers: seq[BufferEntry]; base: string): seq[string] =
  ## Where a name that is not a path is looked for: the directory the command
  ## was typed against first, then the directory of every open tab. This is
  ## nimedit's search path without a list to maintain -- the open tabs already
  ## say which directories a session is about.
  result = @[]
  if base.len > 0 and dirExists(base): result.add normDir(base)
  for b in buffers:
    if b.path.len > 0:
      let d = normDir(b.path.parentDir)
      if d notin result and dirExists(d): result.add d

proc findFileSmart(buffers: seq[BufferEntry]; base, arg: string;
                   truncated: var bool): string =
  ## Three questions, cheapest first, each asked only because the one before it
  ## said no:
  ##
  ## 1. the path as given, against the directory the command was typed in and
  ##    the directory of every open tab -- nimedit's `findFile`;
  ## 2. the *listings* of those same directories, for a name with pieces
  ##    missing -- nimedit's `findFileAbbrev`, one `walkDir` each;
  ## 3. the projects those directories are in, walked.
  ##
  ## The first two look at a handful of directories and answer instantly. What
  ## they cannot answer is a project that has any shape to it: with only
  ## `nimony/README.md` open, `xelim.nim` is three directories away in
  ## `src/hexer/` and no list of open directories will ever hold it. That is
  ## what the walk is for, and why it is last -- it is the only step that costs
  ## anything, and by the time it runs the cheap answers have all said no.
  ##
  ## Steps 2 and 3 are the same ranking over a different scope, so the quick
  ## search and the thorough one can never disagree about which of two files
  ## was meant. Directories are found too; the caller decides what to do with
  ## one.
  truncated = false
  if arg.len == 0: return ""
  let e = expandTilde(arg)
  if isAbsolute(e):
    return if fileExists(e) or dirExists(e): e else: ""
  let dirs = searchDirs(buffers, base)
  for d in dirs:
    let p = d / e
    if fileExists(p) or dirExists(p): return p
  result = findInTrees(dirs, dirs, e, truncated, recurse = false)
  if result.len > 0: return
  var roots: seq[string] = @[]
  for d in dirs:
    let r = searchRoot(d)
    if r.len > 0 and r notin roots: roots.add r
  result = findInTrees(roots, dirs, e, truncated)

proc runOpenCommand(act: TermAction; base: string;
                    buffers: var seq[BufferEntry]; current: var int;
                    font: Font; focus: var string; explorer: var Explorer;
                    note: var string) =
  if act.arg.len == 0:
    note = "open what? try 'o <file>'"
    return
  # `act.file` is what the widget resolved; anything smarter than that is this
  # application's business, because only it knows which files are open.
  var path = act.file
  var truncated = false
  if not fileExists(path) and not dirExists(path):
    path = findFileSmart(buffers, base, act.arg, truncated)
  if path.len == 0:
    note = "cannot open: " & act.arg &
      (if truncated: " -- and the tree was too big to search all of it" else: "")
  elif dirExists(path):
    # A directory is not a buffer; it is what the explorer is for.
    explorer.showDir(path)
    focus = "explorer"
    note = ""
  else:
    current = buffers.openFile(font, path, -1, -1)
    focus = "editor"
    note = ""

proc saveCurrent(buffers: var seq[BufferEntry]; current: int;
                 note: var string) =
  ## Write the buffer back to the file it came from. A buffer that has no file
  ## says so instead of quietly doing nothing.
  if buffers[current].path.len == 0:
    note =
      if buffers[current].isConfig: "[config] saves itself"
      else: "this buffer has no file yet: try 's <name>'"
    return
  try:
    buffers[current].ed.saveToFile(buffers[current].path)
    note = ""
  except CatchableError:
    note = "cannot save " & buffers[current].path & ": " &
           getCurrentExceptionMsg()

proc saveBufferAs(buffers: var seq[BufferEntry]; current: int; path: string;
                  note: var string) =
  ## Write the buffer to `path` and let it belong there from now on.
  try:
    buffers[current].ed.saveToFile(path)
  except CatchableError:
    note = "cannot save " & path & ": " & getCurrentExceptionMsg()
    return
  if buffers[current].isConfig:
    # A copy of the config, not a move: tab 0 is where the window is edited,
    # and `config.nif` under the config dir is where it is read from.
    note = "wrote " & path.extractFilename & "; [config] stays where it is"
    return
  var full = path
  try: full = expandFilename(path)
  except OSError: discard
  buffers[current].path = full
  buffers[current].ed.applyFileKind(full)
  note = ""

type
  SaveOutcome = enum
    saveOver     ## nothing more to do, whether or not a file was written
    saveAsk      ## the name is taken; the answer to that decides

proc runSaveCommand(act: TermAction; buffers: var seq[BufferEntry];
                    current: int; note: var string): SaveOutcome =
  result = saveOver
  if act.arg.len == 0:
    saveCurrent(buffers, current, note)
    return
  let path = act.file
  if path.extractFilename.len == 0:
    note = "not a file name: " & act.arg
    return
  # A name that is already taken is a question, never a silent overwrite.
  if fileExists(path) and cmpPaths(path, buffers[current].path) != 0:
    return saveAsk
  saveBufferAs(buffers, current, path, note)

# ---------------------------------------------------------------------------
# Search and replace -- the commands, and the exchange a replace turns into.
# The hits live in the buffers; `Finder` is what a `next` or an answer needs to
# know to carry on.
# ---------------------------------------------------------------------------

type
  Finder = object
    term, replacement: string
    opts: SearchOptions
    replacing: bool      ## the search was started by `replace`, not by `find`
    allBuffers: bool     ## `findall` / `replaceall`: every open tab, not one
    replaced: int        ## how many replacements the running exchange made

  AskKind = enum
    askNothing
    askOverwrite   ## "<file> exists. Overwrite? [yes|no]"
    askReplace     ## "Replace? [yes|no|all|abort]"

  Ask = object
    ## What the window is waiting to hear, and what the answer will mean. One
    ## per window, and the prompt's alone: the question is shown in the status
    ## bar, so that is the line it is answered in, whichever of the two places
    ## the command that raised it was typed in.
    kind: AskKind
    question: string
    path: string   ## askOverwrite: where the buffer would go

const ReplaceQuestion = "Replace? [yes|no|all|abort]"

proc markAll(buffers: var seq[BufferEntry]; current: int; theme: Theme) =
  ## Paint every hit in every buffer. Only the buffer the finger is in has an
  ## active hit -- elsewhere a hit is just a hit, so that one glance says where
  ## `next` will land.
  for i in 0 ..< buffers.len:
    if buffers[i].search.hits.len > 0:
      buffers[i].search.mark(buffers[i].ed, theme.markerBg,
                             if i == current: theme.selBg else: theme.markerBg)

proc dropSearch(buffers: var seq[BufferEntry]) =
  for b in buffers.mitems:
    if b.search.hits.len > 0:
      b.search.clear()
      b.ed.clearMarkers()

proc searchNote(f: Finder; buffers: seq[BufferEntry]; current: int): string =
  let bs = buffers[current].search
  if bs.hits.len == 0: return "'" & f.term & "': no match in this tab"
  result = "'" & f.term & "' " & $(min(bs.active + 1, bs.hits.len)) & "/" &
           $bs.hits.len
  if f.allBuffers:
    var elsewhere = 0
    for i, b in buffers:
      if i != current: elsewhere += b.search.hits.len
    if elsewhere > 0: result.add " (+" & $elsewhere & " in other tabs)"

proc nextWithHits(buffers: seq[BufferEntry]; current: int;
                  backwards: bool): int =
  ## The next buffer along that has hits, wrapping around -- `current` itself
  ## is the last candidate, which is what makes a single-buffer search wrap
  ## instead of stopping. -1 when nothing was found anywhere.
  let n = buffers.len
  for k in 1 .. n:
    let i = ((current + (if backwards: -k else: k)) mod n + n) mod n
    if buffers[i].search.hits.len > 0: return i
  result = -1

proc runSearchCommand(act: TermAction; buffers: var seq[BufferEntry];
                      current: var int; f: var Finder; theme: Theme;
                      note: var string): bool =
  ## Start a search. True when it turned into a question -- a `replace` that
  ## found something has to ask before it touches the text.
  dropSearch(buffers)
  f = Finder()
  if act.term.len == 0:
    # `find` with nothing to look for is how the highlighting goes away again.
    note = ""
    return false
  f.term = act.term
  f.replacement = act.replacement
  f.opts = parseSearchOptions(act.opts)
  f.replacing = act.replacing
  f.allBuffers = act.allBuffers and currentFileOnly notin f.opts
  for i in 0 ..< buffers.len:
    if i == current or f.allBuffers:
      buffers[i].search.run(buffers[i].ed, f.term, f.opts, f.replacement)
  if buffers[current].search.hits.len == 0:
    let other = nextWithHits(buffers, current, backwards = false)
    if other >= 0: current = other
  markAll(buffers, current, theme)
  if buffers[current].search.hits.len == 0:
    note = "not found: " & f.term
    return false
  buffers[current].search.gotoActive(buffers[current].ed)
  note = searchNote(f, buffers, current)
  result = f.replacing

proc gotoNextMatch(buffers: var seq[BufferEntry]; current: var int;
                   f: Finder; backwards: bool; theme: Theme;
                   note: var string) =
  if f.term.len == 0:
    note = "no search yet -- try 'find <text>'"
    return
  var total = 0
  for b in buffers: total += b.search.hits.len
  if total == 0:
    # The text was edited, so the hits went with it. The term is still the one
    # that was asked for, so look again rather than answer "not found" about a
    # search nobody withdrew. The finger lands at the caret, which is where
    # this was going to move it anyway.
    for i in 0 ..< buffers.len:
      if i == current or f.allBuffers:
        buffers[i].search.run(buffers[i].ed, f.term, f.opts, f.replacement)
    if buffers[current].search.hits.len == 0:
      let other = nextWithHits(buffers, current, backwards)
      if other < 0:
        note = "not found: " & f.term
        return
      current = other
      buffers[current].search.rewind(toLast = backwards)
    markAll(buffers, current, theme)
    buffers[current].search.gotoActive(buffers[current].ed)
    note = searchNote(f, buffers, current)
    return
  if not buffers[current].search.step(backwards):
    # Off the end of this buffer: on to the next one that has something, which
    # for a search of one buffer is this one again.
    let nxt = nextWithHits(buffers, current, backwards)
    if nxt < 0:
      note = "not found: " & f.term
      return
    current = nxt
    buffers[current].search.rewind(toLast = backwards)
  markAll(buffers, current, theme)
  buffers[current].search.gotoActive(buffers[current].ed)
  note = searchNote(f, buffers, current)

proc nextPending(buffers: var seq[BufferEntry]; current: var int;
                 f: Finder): bool =
  ## Put the finger on the next hit still waiting for an answer, moving on to
  ## another buffer once this one is through. False when the exchange is over.
  if not buffers[current].search.done: return true
  if f.allBuffers:
    for i in 0 ..< buffers.len:
      if i != current and not buffers[i].search.done and
         buffers[i].search.hits.len > 0:
        current = i
        return true
  result = false

proc runAnswer(word: string; asked: var Ask; f: var Finder;
               buffers: var seq[BufferEntry]; current: var int;
               theme: Theme; note: var string): string =
  ## Act on the answer. Returns the next question, or "" when the exchange is
  ## over -- the caller arms the widget that asked with whatever comes back.
  result = ""
  case asked.kind
  of askNothing:
    note = "nothing to answer"
  of askOverwrite:
    if word.startsWith("y"):
      saveBufferAs(buffers, current, asked.path, note)
    else:
      note = "not saved"
    asked = Ask()
  of askReplace:
    case word
    of "y", "yes":
      if not buffers[current].search.replaceActive(buffers[current].ed):
        # The hit is not there to be replaced: the text moved under it between
        # the question and the answer. Better to stop than to write into a
        # place that is no longer the one that was asked about.
        dropSearch(buffers)
        note = "the text changed -- search again"
        asked = Ask()
        return ""
      inc f.replaced
    of "n", "no":
      buffers[current].search.skipActive()
    of "all":
      # Every hit of this search, from the top of each buffer: `all` means the
      # ones already passed over as well.
      for b in buffers.mitems:
        if b.search.hits.len == 0: continue
        b.search.rewind(toLast = false)
        while b.search.replaceActive(b.ed): inc f.replaced
      dropSearch(buffers)
      note = "replaced " & $f.replaced
      asked = Ask()
      return ""
    of "a", "abort", "q", "quit":
      note = (if f.replaced > 0: "stopped after " & $f.replaced
              else: "nothing replaced")
      asked = Ask()
      return ""
    else:
      note = "'" & word & "'? " & ReplaceQuestion
      return ReplaceQuestion
    if nextPending(buffers, current, f):
      markAll(buffers, current, theme)
      buffers[current].search.gotoActive(buffers[current].ed)
      note = searchNote(f, buffers, current) & "  " & ReplaceQuestion
      return ReplaceQuestion
    dropSearch(buffers)
    note = "replaced " & $f.replaced
    asked = Ask()

proc runDefaults(buffers: var seq[BufferEntry]; note: var string) =
  ## `defaults`: put the config the app ships with back into the [config] tab.
  ## Written as an edit rather than as a new text, so Ctrl+Z in that tab brings
  ## a hand-written config back -- which is why this asks nothing first: what
  ## it replaces is one keystroke away for as long as the tab is open. The
  ## main loop does the rest, since it already reparses and stores that buffer
  ## whenever it changed.
  for b in buffers.mitems:
    if b.isConfig:
      if b.ed.fullText == defaultConfig:
        note = "the config already is the default one"
      elif b.ed.len > 0:
        b.ed.replaceRange(0, b.ed.len - 1, defaultConfig)
        note = "config back to the defaults; Ctrl+Z in [config] undoes it"
      else:
        b.ed.insertText(defaultConfig)
        note = "config back to the defaults"
      return
  note = "there is no [config] tab to put it in"

proc runSave(act: TermAction; asked: var Ask; buffers: var seq[BufferEntry];
             current: int; note: var string) =
  ## `save`, with the question it may raise.
  case runSaveCommand(act, buffers, current, note)
  of saveOver: discard
  of saveAsk:
    asked = Ask(kind: askOverwrite, path: act.file,
                question: act.file.extractFilename &
                          " exists. Overwrite? [yes|no]")
    note = asked.question

proc runSearch(act: TermAction; asked: var Ask; f: var Finder;
               buffers: var seq[BufferEntry]; current: var int; theme: Theme;
               note: var string) =
  if runSearchCommand(act, buffers, current, f, theme, note):
    asked = Ask(kind: askReplace, question: ReplaceQuestion)
    note = note & "  " & ReplaceQuestion

proc adjustFocusedFontSize(
    focus: string; delta: int;
    fonts: var Table[int, Font];
    history: var SynEdit;
    tabs: var TabList; explorer: var Explorer;
    term, status: var Terminal; clips: var ClipHistory;
    buffers: var seq[BufferEntry]; current: int;
    panelFontSize, historyFontSize,
    terminalFontSize, statusFontSize, editorFontSize: var int) =
  case focus
  of "tabs", "explorer", "clipboard":
    panelFontSize = clamp(panelFontSize + delta, MinFontSize, MaxFontSize)
    let f = fonts.fontForSize(panelFontSize)
    tabs.ed.setFont(f)
    explorer.ed.setFont(f)
    clips.setFont(f)
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
  # The icon goes in with it: it is the bitmap a window manager shows when no
  # .desktop entry is installed to look one up in, and it has to be there
  # before the window is, or the desktop draws its placeholder first. Who the
  # window belongs to needs nothing said about it -- `createWindow` puts the
  # name of this executable in WM_CLASS, which is the "focim" a
  # StartupWMClass matches.
  let screen = createWindow(MaxWindowWidth, MaxWindowHeight,
                            icon = focimIcon())
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
  # What makes this one the prompt rather than a second terminal: it takes the
  # questions (`question`), it resolves relative paths against the current tab
  # (`baseDir`, set every frame below), and it is where a command that acts on
  # the app itself is typed.
  status.isPrompt = true
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
  var trackSpec = defaultTrack()
  var configNote = ""
  reparseConfig(defaultConfig, width, height, fm.lineHeight, layout, theme,
                trackSpec, configNote)
  doAssert configNote.len == 0, configNote
  var configText = loadConfig("config.nif")
  if configText.len > 0:
    reparseConfig(configText, width, height, fm.lineHeight, layout, theme,
                  trackSpec, configNote)
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
  var lastTitle = ""

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
  # What the clipboard held. Nothing reports a copy to us -- the editor's own
  # Ctrl+C goes to the system clipboard like everybody else's -- so this is
  # read rather than told, which is also what picks up a copy made in another
  # application.
  var clips = initClipHistory(fonts.fontForSize(panelFontSize))

  # The last search, and what the prompt is waiting to hear about. Both are
  # one per window: a question that nobody can see is worse than none, and
  # there is one status bar to show it in.
  var finder = Finder()
  var asked = Ask()

  # The outstanding "where is this name?", and the places its answer named.
  # `jumps` outlives the listing that offers them by exactly one keystroke: the
  # listing hands back a row number and this is what turns one into a place.
  var tracker = Tracker()
  var jumps: seq[TrackHit] = @[]

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
                      trackSpec, configNote)
        if configNote.len == 0: saveConfig("config.nif", src)
        b.ed.markSaved()

    # The theme goes out to every widget every frame. Buffers come and go and
    # the colors can change with any keystroke in the config, so there is no
    # single place to hook this that could not be forgotten later.
    #
    # Everything that is not the text being edited draws on `panelBg` instead
    # of on `bg`: one color for the whole window makes a tab list, a listing
    # and a terminal look like more of the document, and the eye has to find
    # the seams before it can find the text.
    var panelTheme = theme
    panelTheme.bg = theme.panelBg
    history.theme = panelTheme
    tabs.ed.theme = panelTheme
    explorer.ed.theme = panelTheme
    term.ed.theme = panelTheme
    status.ed.theme = panelTheme
    comp.theme = panelTheme
    comp.setFont buffers[current].ed.getFont
    clips.theme = panelTheme
    # The prompt has no directory of its own, so a relative path typed there is
    # taken to be relative to the file being edited -- the same thing that path
    # would mean written inside that file. The terminal has a `cwd` and a `cd`
    # to move it with, and keeps resolving against those.
    status.baseDir =
      if buffers[current].path.len > 0: buffers[current].path.parentDir
      else: os.getCurrentDir()
    # Whether or not the layout shows the panel: what was copied while it was
    # hidden is exactly what somebody goes looking for after showing it.
    clips.poll()
    for b in buffers.mitems: b.ed.theme = theme

    # A question is the prompt's business, wherever the command that raised it
    # was typed: it is shown in the status bar, so that is the line it is
    # answered in, and the focus moves there when it is put. The terminal is
    # never armed -- it is where programs run, and `yes` is one of them.
    # `runCommand` clears its own copy when it hands the answer over.
    status.question = asked.question

    # An edit that the search did not make has moved every hit behind it, so
    # the hits go, and the highlighting with them. What was typed is what the
    # user is looking at now -- not what the search found before it.
    for b in buffers.mitems:
      if b.search.stale(b.ed):
        b.search.clear()
        b.ed.clearMarkers()

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

    # The compiler answers frames after the click that asked it, which is the
    # whole point of asking in a thread -- so nothing here may assume the
    # editor still looks the way it did when the question was put.
    tracker.update()
    if tracker.note.len > 0:
      tabs.note = tracker.note
      tracker.note = ""
    if tracker.ready:
      tracker.ready = false
      jumps = tracker.hits
      if jumps.len == 1:
        # One place is not a choice. A listing of it would be a keystroke
        # asking which of the one.
        jumpTo(jumps[0], buffers, current, fonts.fontForSize(editorFontSize),
               focus, tabs.note)
        jumps.setLen 0
      else:
        comp.choose(trackRows(jumps, tracker.project.parentDir, buffers),
                    buffers[current].ed)
        focus = "editor"

    let cells = layout.resolve(width, height, fm.lineHeight,
                               padding = scaledPx(6), gap = scaledPx(4),
                               uiScale = gUiScale)

    # Only ever one question is outstanding, and anything the user starts
    # instead of answering it withdraws it -- otherwise the next line typed
    # would be read as an answer to something nobody can see any more.
    template endExchange() =
      asked = Ask()
      status.question = ""
    template endExchange(a: TermAction) =
      if a.kind notin {TermActionKind.noAction, TermActionKind.ctrlHover,
                       TermActionKind.ctrlClick, answer}:
        endExchange()
    # A layout may have dropped the cell that had the focus.
    if focus notin cells: focus = "editor"

    # Fill background -- gaps between cells show this color as borders, so it
    # comes from the theme: `actionColor` is what the theme already uses to
    # frame things.
    fillRect(rect(0, 0, width, height), theme.actionColor)

    var e = default Event
    # An index job is the one thing here that has work of its own to do: while
    # one runs the loop only polls, so the job gets every frame instead of one
    # every half second. A compiler answering a Ctrl+click has work of its own
    # too, but it is doing it in another thread and all this one has to do is
    # notice -- often enough that the answer feels like it belongs to the
    # click, rarely enough to cost nothing while the compiler thinks.
    discard waitEvent(e, if job.active: 0 elif tracker.busy: 50 else: 500,
                      {WantTextInput})
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
      of "clipboard": clips.wheelScroll(e.y)
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
      # Ctrl+Space, Ctrl+<digit> and Ctrl+<letter> are commands, not text. X11
      # hands the app both, and the character would land in the buffer right
      # where the paste is about to go -- or, for a letter, as the control
      # character it stands for; the key event above has already dealt with it.
      if CtrlPressed in e.mods and e.text[1] == '\0' and
         (e.text[0] in {' ', '1'..'9'} or e.text[0] < ' '):
        e = default Event
    of KeyDownEvent:
      let cmd = CtrlPressed in e.mods or GuiPressed in e.mods
      if cmd and e.key == KeyS:
        saveCurrent(buffers, current, tabs.note)
        e = default Event  # consume the event
      elif cmd and e.key == KeyP:
        # "Quick open", for the muscle memory every other editor has trained:
        # the prompt, with the command already typed, so that the file name is
        # all that is left to do. It is the ordinary `open` command -- Tab
        # completes it and Enter runs it like any other.
        if "status" in cells:
          endExchange()
          prepareCommand(status, buffers, current, "open ", tabs.note)
          focus = "status"
        else:
          # A layout without a status bar has nowhere to type it.
          tabs.note = "no 'status' cell in the layout"
        e = default Event  # consume the event
      elif cmd and e.key == KeyF:
        # The same quick way in as Ctrl+P, for the other command one reaches
        # for without thinking. `find ` and not `f `: the long name is the one
        # that says what the line is about while it is being typed.
        if "status" in cells:
          endExchange()
          prepareCommand(status, buffers, current, "find ", tabs.note)
          focus = "status"
        else:
          tabs.note = "no 'status' cell in the layout"
        e = default Event  # consume the event
      elif e.key == KeyF3:
        # What every other editor puts there, and the reason `next` and `prev`
        # do not have to be typed to walk a search. Moving the finger while a
        # replace was asking about a match would answer for a different one,
        # so it withdraws the question like any other command.
        endExchange()
        gotoNextMatch(buffers, current, finder, ShiftPressed in e.mods, theme,
                      tabs.note)
        focus = "editor"
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
                              tabs, explorer, term, status, clips,
                              buffers, current,
                              panelFontSize, historyFontSize,
                              terminalFontSize, statusFontSize, editorFontSize)
        e = default Event  # consume the event
      elif cmd and e.key in {Key1 .. Key9} and focus == "editor" and
           "clipboard" in cells:
        # The panel is numbered, so a row is taken by its number rather than by
        # being selected first. Nothing has to be up, nothing has to be aimed
        # at, and the arrow keys stay where they belong.
        let text = clips.entry(ord(e.key) - ord(Key1) + 1)
        if text.len > 0: buffers[current].ed.insertText(text)
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
        let pick = comp.chosen
        if pick >= 0 and pick < jumps.len:
          # A listing of places rather than of words: taking a row goes there.
          jumpTo(jumps[pick], buffers, current,
                 fonts.fontForSize(editorFontSize), focus, tabs.note)
          jumps.setLen 0
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

    # The window title says which buffer is in the editor, out of the same
    # names the tab list shows -- so the two cannot disagree, and a name that
    # had to be made unique ("doc/config.md") is unique in the title too.
    #
    # Driven by what *is* current rather than set wherever something gets
    # opened: the current buffer also changes by switching tabs, by closing
    # one, and by undoing that, and none of those go through an open.
    let title = if current < tabs.names.len: tabs.names[current] else: ""
    if title != lastTitle:
      lastTitle = title
      setWindowTitle(if title.len > 0: "focim - " & title else: "focim")

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
      elif buffers[current].ed.lang == langNim:
        # Where is this name? Only a compiler knows, so one is asked -- and the
        # answer arrives some frames from now, at the top of the loop.
        startTrack(tracker, trackSpec, buffers[current].ed, edAct.pos,
                   buffers[current].path, tabs.note)
    of ctrlHover:
      if buffers[current].ed.lang == langMarkdown:
        let (_, a, b) = buffers[current].ed.markdownLinkAt(edAct.pos)
        buffers[current].ed.underline(a, b)
      elif buffers[current].ed.lang == langNim:
        # The name under the pointer is what the click would ask about, so it
        # is what gets underlined -- the same promise the markdown links make.
        let (word, a, b) = buffers[current].ed.wordAt(edAct.pos)
        if word.len > 0: buffers[current].ed.underline(a, b)
        else: buffers[current].ed.underline(-1, -1)
    of closeLine:
      discard # the editor has no close buttons
    of noAction:
      buffers[current].ed.underline(-1, -1)

    # Clipboard panel -- what the clipboard held, newest first. Drawn only when
    # the layout shows it, which is the same thing Ctrl+<digit> checks: a row
    # nobody can read is a row nobody can pick a number out of.
    if "clipboard" in cells:
      let clipAct = clips.draw(e, cells["clipboard"], focus == "clipboard")
      if clipAct.drop > 0:
        # The (x) forgets an entry -- which is how a password copied by mistake
        # stops being one keystroke away from every buffer.
        clips.drop clipAct.drop
      elif clipAct.take > 0:
        # Clicking a row pastes it and hands the caret straight back: nobody
        # clicks a clipping in order to end up in the panel.
        buffers[current].ed.insertText(clips.entry(clipAct.take))
        focus = "editor"

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
    endExchange(termAct)
    case termAct.kind
    of openFile:
      runOpenCommand(termAct, term.base, buffers, current,
                     fonts.fontForSize(editorFontSize), focus, explorer,
                     tabs.note)
    of saveFile:
      runSave(termAct, asked, buffers, current, tabs.note)
      # A command typed here may still end in a question, and the question is
      # put in the prompt -- so that is where the caret goes to answer it.
      if asked.question.len > 0: focus = "status"
    of searchText:
      runSearch(termAct, asked, finder, buffers, current, theme, tabs.note)
      if asked.question.len > 0: focus = "status"
    of gotoMatch:
      gotoNextMatch(buffers, current, finder, termAct.backwards, theme,
                    tabs.note)
    of answer:
      # Unreachable: only the prompt is ever armed with a question.
      discard
    of indexWords:
      runIndexCommand(termAct, words, job, tabs.note)
    of resetConfig:
      # Unreachable: `defaults` is the prompt's command, and this is the
      # terminal -- there the word is a program's name.
      discard
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
    template redrawStatus() =
      # The command has just changed what the line says about the buffer, and
      # the prompt it left behind belongs to a terminal, not to a status bar.
      updateStatus(status, buffers[current].ed, buffers[current].path,
                   if configNote.len > 0: configNote else: tabs.note)
    endExchange(statusAct)
    case statusAct.kind
    of openFile:
      runOpenCommand(statusAct, status.base, buffers, current,
                     fonts.fontForSize(editorFontSize), focus, explorer,
                     tabs.note)
      redrawStatus()
    of saveFile:
      runSave(statusAct, asked, buffers, current, tabs.note)
      # A question keeps the focus here: the answer is typed into the line the
      # question is shown in. Anything else is finished with, and the caret
      # belongs back in the text.
      if asked.question.len == 0: focus = "editor"
      redrawStatus()
    of searchText:
      runSearch(statusAct, asked, finder, buffers, current, theme, tabs.note)
      if asked.question.len == 0: focus = "editor"
      redrawStatus()
    of gotoMatch:
      gotoNextMatch(buffers, current, finder, statusAct.backwards, theme,
                    tabs.note)
      focus = "editor"
      redrawStatus()
    of answer:
      asked.question = runAnswer(statusAct.word, asked, finder, buffers,
                                 current, theme, tabs.note)
      if asked.question.len == 0: focus = "editor"
      redrawStatus()
    of indexWords:
      runIndexCommand(statusAct, words, job, tabs.note)
    of resetConfig:
      runDefaults(buffers, tabs.note)
      redrawStatus()
    of ctrlHover, ctrlClick, noAction: discard

    # The completion listing, last: it goes over everything, and it can only
    # be placed once the editor has drawn the caret it hangs from.
    comp.draw(words, buffers[current].ed, cells["editor"], focus == "editor")

    # Which panel the next keystroke goes to, said once and in one place. The
    # frame lands in the gap the layout leaves between the cells -- half of it
    # per side, so two neighbours cannot both claim the same pixel -- and
    # therefore takes no room from the widget and cannot move its text.
    if focus in cells:
      # Clamped to the window: a cell against an edge has no gap on that side,
      # and a frame drawn past it would simply not be there.
      let f = cells[focus]
      let fw = scaledPx(2)
      let x0 = max(0, f.x - fw)
      let y0 = max(0, f.y - fw)
      let x1 = min(width - 1, f.x + f.w - 1 + fw)
      let y1 = min(height - 1, f.y + f.h - 1 + fw)
      drawFrame(rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1), theme.focusColor, fw)

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
