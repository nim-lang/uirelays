## completion.nim -- the listing of words that could continue what is being
## typed, drawn under the caret of the editor it completes.
##
## It lives next to focim rather than under `widgets/` because it is not a
## general purpose widget yet: it knows that its candidates come out of a
## `WordIndex`, that what it points at is a SynEdit with a caret in it, and
## that the word being completed is the one the caret sits behind. A widget
## would take a `seq[string]` and a rectangle and let its host answer all
## three. That is a small change and the day something else wants a listing
## under a caret is the day to make it -- until then this is one app's screen
## furniture, and pretending otherwise would only fix the wrong shape in
## place.
##
## Nothing is ever typed *into* it. The caret stays in the editor, so an
## ordinary keystroke narrows the listing rather than leaving it: the host
## offers every key to `handleKey` first, and everything the listing does not
## claim reaches the buffer as usual. `draw` then reads the prefix back out
## of the buffer, which is why typing, backspace and a paste all work without
## anyone having to say which of them happened.
##
## `choose` is the same listing asked a different question: instead of "which
## word did you mean", "which of these places did you mean". It is what a
## Ctrl+click offers the definition and the usages of a name in -- one keyboard
## habit for both, and no second popup to build. The rows are the host's, not
## the index's, so nothing narrows them and `taken` says which one was picked
## rather than the listing writing it into the buffer.

import uirelays
import widgets/[synedit, wordindex]

const
  MaxRows* = 10
    ## How tall the listing gets. Also how far PageUp and PageDown move, so
    ## that a page is what a page looks like.
  ClaimedKeys = {KeyUp, KeyDown, KeyPageUp, KeyPageDown, KeyEsc, KeyEnter,
                 KeyTab}
    ## The keys that mean something to a listing. Everything else belongs to
    ## the buffer, including the sideways arrows -- moving along a line is not
    ## a decision about the listing, and the prefix it lands on says what the
    ## listing should be.

type
  Completion* = object
    ed: SynEdit          ## the listing itself; everything here is text
    open: bool
    items: seq[string]
    sel: int
    pre: string          ## the word prefix `items` was built for
    version: int         ## the index version it was built from
    choosing: bool       ## the rows are the host's places, not words to type
    anchor: int          ## where the caret stood when `choose` opened it
    taken: int           ## the row `choosing` ended on, -1 while it has not

proc initCompletion*(font: Font): Completion =
  result = Completion(ed: createSynEdit(font), taken: -1)
  # A candidate is a name, not code: nothing to colorize, nothing to number.
  result.ed.lang = langNone

proc active*(c: Completion): bool {.inline.} = c.open
proc prefix*(c: Completion): string {.inline.} = c.pre
  ## What the listing was last built for -- worth having even when nothing
  ## matched, since that is what a message about it has to name.

proc setFont*(c: var Completion; f: Font) {.inline.} = c.ed.setFont f
proc `theme=`*(c: var Completion; t: Theme) {.inline.} = c.ed.theme = t

proc dismiss*(c: var Completion) =
  c.open = false
  c.choosing = false
  c.taken = -1
  c.items.setLen 0

proc highlight(c: var Completion) =
  ## The selected row, as a marker rather than as text -- the same way the tab
  ## list marks the active tab.
  c.ed.clearMarkers()
  var pos = 0
  for i, w in c.items:
    if i == c.sel:
      c.ed.addMarker(pos, pos + max(w.len, 1) - 1, c.ed.theme.selBg)
      break
    pos += w.len + 1
  c.ed.gotoLine(c.sel + 1, 0)

proc refill(c: var Completion; words: var WordIndex; prefix: string) =
  c.pre = prefix
  c.version = words.version
  c.items = words.complete(prefix)
  c.sel = 0
  c.open = c.items.len > 0
  if c.open:
    var text = ""
    for i, w in c.items:
      if i > 0: text.add "\n"
      text.add w
    c.ed.setText(text)
    c.highlight()

proc move(c: var Completion; delta: int) =
  if c.items.len == 0: return
  c.sel = clamp(c.sel + delta, 0, c.items.high)
  c.highlight()

proc show*(c: var Completion; words: var WordIndex; ed: SynEdit) =
  ## What Ctrl+Space asks for: the words that could continue the one the caret
  ## sits behind. `active` is false afterwards when none could, and `prefix`
  ## says what was asked for.
  c.choosing = false
  c.taken = -1
  c.refill(words, ed.getWordPrefix)

proc choose*(c: var Completion; rows: seq[string]; ed: SynEdit) =
  ## Offer `rows` under the caret and wait to be told which one. Nothing about
  ## them is a word, so nothing narrows them: the prefix machinery is off and
  ## the listing lives until it is picked from, dismissed, or the caret moves
  ## out from under it.
  c.items = rows
  c.sel = 0
  c.pre = ""
  c.choosing = true
  c.taken = -1
  c.anchor = ed.cursor
  c.open = rows.len > 0
  if c.open:
    var text = ""
    for i, w in c.items:
      if i > 0: text.add "\n"
      text.add w
    c.ed.setText(text)
    c.highlight()

proc chosen*(c: var Completion): int =
  ## Which row a `choose` ended on, once and once only: -1 when the listing is
  ## still up, was dismissed, or has already been asked. Reading it clears it,
  ## so a host that forgets to act on the answer cannot act on it twice.
  result = c.taken
  c.taken = -1

proc handleKey*(c: var Completion; e: Event; ed: var SynEdit): bool =
  ## Offer a key to the listing. True when it took it -- the host consumes the
  ## event then, so the editor does not act on it as well.
  if not c.open or e.kind != KeyDownEvent or e.key notin ClaimedKeys:
    return false
  case e.key
  of KeyUp: c.move(-1)
  of KeyDown: c.move(1)
  of KeyPageUp: c.move(-MaxRows)
  of KeyPageDown: c.move(MaxRows)
  of KeyEsc: c.dismiss()
  else:
    # Enter and Tab both take the selection.
    if c.choosing:
      # A place to go to, which is the host's business: it is told the row and
      # decides what going there means.
      let sel = c.sel
      c.dismiss()
      c.taken = sel
    else:
      # One `version` in SynEdit covers the whole swap, so one Ctrl+Z takes
      # the completion back.
      ed.replaceWordPrefix(c.items[c.sel])
      c.dismiss()
  result = true

proc draw*(c: var Completion; words: var WordIndex; ed: SynEdit; area: Rect;
           focused: bool) =
  ## Per-frame entry point, to be called *after* the editor has drawn: that is
  ## what says where the caret is, and drawing last is what puts the listing
  ## over everything else. `area` is the editor's own cell, which the listing
  ## stays inside, so it can never end up over a panel it has nothing to do
  ## with.
  if not c.open: return
  if not focused:
    # The listing belongs to a caret that is being typed at. Somewhere else
    # having the focus means there is no such caret any more.
    c.dismiss()
    return
  if c.choosing:
    # Rows the host put there: nothing about the buffer can change what they
    # say. What ends them is the caret leaving the name they were offered for
    # -- typing, a click, an arrow that the listing did not claim.
    if ed.cursor != c.anchor:
      c.dismiss()
      return
  else:
    let p = ed.getWordPrefix
    if p.len == 0 and c.pre.len > 0:
      # The word it was opened on is gone.
      c.dismiss()
      return
    if p != c.pre or words.version != c.version:
      c.refill(words, p)
      if not c.open: return
  let caret = ed.cursorRect
  if caret.h == 0:
    # The caret is not on screen -- the buffer scrolled away from it. There is
    # nothing to point at, so there is nothing to show.
    c.dismiss()
    return
  let lineH = fontLineSkip(c.ed.getFont)
  if lineH <= 0: return
  var longest = 0
  for w in c.items: longest = max(longest, w.len)
  let charW = max(1, measureText(c.ed.getFont, "n").w)
  # The listing draws inside its box the way every SynEdit does, so the box is
  # the text plus that padding; without it the last row would fall outside.
  let pad = c.ed.padding
  let pw = clamp((longest + 3) * charW + 2 * pad.x, 16 * charW,
                 max(16 * charW, area.w - 8))
  let ph = clamp(c.items.len, 1, MaxRows) * lineH + 2 * pad.y + 4
  let px = clamp(caret.x, area.x, max(area.x, area.x + area.w - pw - 2))
  var py = caret.y + caret.h + 2
  if py + ph > area.y + area.h:
    # No room below: above the caret, unless the caret is so high up that
    # there is no room there either.
    py = if caret.y - ph - 2 >= area.y: caret.y - ph - 2
         else: max(area.y, area.y + area.h - ph)
  fillRect(rect(px - 1, py - 1, pw + 2, ph + 2), c.ed.theme.actionColor)
  c.ed.render(rect(px, py, pw, ph), showCursor = false)
