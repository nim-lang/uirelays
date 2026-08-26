## cliphistory.nim -- everything that has been on the clipboard, still there.
##
## A system clipboard holds one thing. Copy a second thing and the first is
## gone, which is why copying twice before pasting once is a mistake everybody
## makes and nobody can undo. This keeps what the clipboard held: a numbered
## list of the last `MaxEntries` texts that entered it, from this application
## or from any other, each one a keystroke away.
##
## It is a panel and not a popup, so there is nothing to summon and nothing to
## dismiss: the rows are numbered, `Ctrl+1` .. `Ctrl+9` take them, and the
## arrow keys never leave the editor. Rows past the ninth have no number,
## because a number nothing can accept is a lie; they are taken with the mouse.
##
## Nothing is written to disk. A clipboard carries passwords, licence keys and
## whatever else was in the last window -- keeping that in a file the editor
## restores at the next start would be a decision for whoever copied it to
## make, not for an editor to make quietly.
##
## The host calls `poll` every frame; what that costs is one clipboard read,
## and only when `PollMs` has gone by since the last one.

import std/monotimes
import std/times except Time
import synedit
import ../uirelays/[coords, screen, input]

const
  MaxEntries* = 30
    ## How much is kept. Nine are ever a keystroke away and the rest are
    ## scrolled to, which is about as far back as anybody remembers copying.
  KeyedRows* = 9
    ## `Ctrl+1` .. `Ctrl+9`, and there is no `Ctrl+10`.
  MaxRowLen* = 120
    ## What is shown of an entry. The row is a label; the entry is the text.
  PollMs* = 200
    ## How often the clipboard is actually read. A copy is a hand movement, so
    ## a fifth of a second is not noticed -- and a keystroke does not pay for a
    ## clipboard read.

type
  ClipHistory* = object
    ed: SynEdit            ## the panel is a listing, and a listing is text
    entries: seq[string]   ## newest first
    last: string           ## what the clipboard said when it was last read
    seeded: bool           ## the first read is what is there already
    at: MonoTime           ## when that read happened
    dirty: bool            ## the listing is behind the entries
    pollMs*: int           ## `PollMs`, and 0 for a caller that has its own
                           ## idea of when to look -- a test, say

  ClipAction* = tuple
    take: int              ## the row to paste, counting from 1; 0 for none
    drop: int              ## the row to forget; 0 for none

proc initClipHistory*(font: Font): ClipHistory =
  result = ClipHistory(ed: createSynEdit(font), at: getMonoTime(),
                       pollMs: PollMs)
  # A copied text is a label here, not code to colorize.
  result.ed.lang = langNone
  # Framed rows with an (x), exactly like the tab list and the history panel:
  # a row is something to act on, and forgetting one is how a password that
  # was copied by mistake stops being one keystroke away.
  result.ed.setActionLines(0)
  result.ed.setCloseButtons(0)
  result.dirty = true

proc setFont*(c: var ClipHistory; f: Font) {.inline.} = c.ed.setFont f
proc `theme=`*(c: var ClipHistory; t: Theme) {.inline.} = c.ed.theme = t
proc `blinks=`*(c: var ClipHistory; v: bool) {.inline.} = c.ed.blinks = v
proc wheelScroll*(c: var ClipHistory; delta: int) {.inline.} =
  c.ed.wheelScroll delta

proc len*(c: ClipHistory): int {.inline.} = c.entries.len
proc entry*(c: ClipHistory; row: int): string =
  ## What row `row` holds, counting from 1 as the panel does, or "" when there
  ## is no such row -- so a caller can hand a keystroke on unhandled.
  if row >= 1 and row <= c.entries.len: c.entries[row - 1] else: ""

proc add*(c: var ClipHistory; text: string) =
  ## Remember a text that entered the clipboard. A text that is already in the
  ## list moves to the front rather than being kept twice: copying the same
  ## thing again says it is wanted again, not that the list wants two of it.
  if text.len == 0: return
  for i in 0 ..< c.entries.len:
    if c.entries[i] == text:
      if i > 0:
        c.entries.delete i
        c.entries.insert text, 0
        c.dirty = true
      return
  c.entries.insert text, 0
  if c.entries.len > MaxEntries: c.entries.setLen MaxEntries
  c.dirty = true

proc drop*(c: var ClipHistory; row: int) =
  ## Forget one entry. What the clipboard itself holds is not touched -- this
  ## list is the only place the older ones exist, and the newest one is still
  ## a `Ctrl+V` away wherever it came from.
  if row >= 1 and row <= c.entries.len:
    c.entries.delete row - 1
    c.dirty = true

proc poll*(c: var ClipHistory): bool =
  ## Pick up whatever has entered the clipboard since the last look, whichever
  ## application put it there. This is the only way in: a copy made in the
  ## editor goes to the system clipboard first and comes back here, so there is
  ## one path and not two, and nothing has to be threaded through SynEdit.
  ##
  ## True when the look found something, which is the only way this panel can
  ## have changed without anybody touching this application: a host that draws
  ## when its window has changed rather than on a timer has no other way to
  ## hear about a copy made in a browser.
  result = false
  let now = getMonoTime()
  if not c.seeded:
    c.seeded = true
  elif (now - c.at).inMilliseconds < c.pollMs:
    return
  c.at = now
  let text = getClipboardText()
  if text == c.last: return
  c.last = text
  c.add text
  result = true

proc rowLabel*(text: string): string =
  ## One line for an entry: its first line with something on it, tabs and runs
  ## of blanks squeezed out, and a note of how much did not fit.
  var lines = 1
  var start = -1
  var stop = -1
  var done = false       ## the first line with something on it has ended
  for i in 0 ..< text.len:
    let c = text[i]
    if c == '\L':
      inc lines
      if stop > start: done = true
    elif not done and c notin {' ', '\t', '\r'}:
      if start < 0: start = i
      stop = i + 1
  var i = 0
  result = newStringOfCap(MaxRowLen + 16)
  if start >= 0 and stop > start:
    i = start
    var cut = false
    while i < stop:
      if result.len >= MaxRowLen: cut = true; break
      if text[i] in {' ', '\t', '\r'}:
        result.add ' '
        while i < stop and text[i] in {' ', '\t', '\r'}: inc i
      else:
        result.add text[i]
        inc i
    if cut: result.add "..."
  else:
    # Whitespace only: there is nothing to show, so say what it is instead.
    result.add "(blank)"
  if lines > 1:
    result.add "  (+"
    result.add $(lines - 1)
    result.add(if lines == 2: " line)" else: " lines)")

proc rebuild(c: var ClipHistory) =
  var text = ""
  if c.entries.len == 0:
    text = "nothing has been copied yet"
  else:
    for i, e in c.entries:
      if i > 0: text.add "\n"
      # A number for what a number can take, and a dash for the rest.
      text.add(if i < KeyedRows: $(i + 1) else: "-")
      text.add ' '
      text.add rowLabel(e)
  # The one row that is not an entry is not framed either, and so does not
  # invite the click it would ignore.
  c.ed.setActionLines(if c.entries.len == 0: -1 else: 0)
  c.ed.setCloseButtons(if c.entries.len == 0: -1 else: 0)
  c.ed.setText(text)
  c.ed.gotoLine(1, 0)
  # `setText` counts as an edit; saying so here is what lets the next frame
  # tell a rebuild apart from somebody typing into the panel.
  c.ed.markSaved()
  c.dirty = false

proc draw*(c: var ClipHistory; e: Event; area: Rect; focused: bool):
          ClipAction =
  ## Draw the panel and report what the mouse did with it. The caret is never
  ## here, so `focused` decides only who gets the wheel and the click.
  result = (0, 0)
  if c.dirty or c.ed.changed: c.rebuild()
  let act = c.ed.draw(e, area, focused)
  if act.kind == closeLine:
    result.drop = act.line + 1
  elif focused and e.kind == MouseDownEvent:
    let row = c.ed.currentLine + 1
    if row <= c.entries.len: result.take = row
