## prediction.nim -- a panel that says what could be written next, in a cell of
## its own rather than over the text it is about.
##
## The overlay in `completion.nim` has to be summoned, because it covers the
## code you are writing it against: it needs a key to appear, a key to leave,
## and it has to take the arrows away from the editor while it is up. A panel
## has none of those problems, and losing them is worth more than not covering
## the text:
##
## * It is always on, so there is nothing to summon and nothing to dismiss.
## * The rows are numbered and `Ctrl+1` .. `Ctrl+9` take them, so there is no
##   selection to move and the arrow keys never leave the editor.
## * The caret never comes here, so nothing has to be handed back afterwards.
##
## That makes it the right home for suggestions longer than a word -- a
## construct spelled across a whole row is unreadable in a popup sitting on top
## of the line it would replace.
##
## Which is what it offers. A row is a run of tokens somebody has written
## before, looked up under as much of the current line as agrees with one, so
## `case ` finds `case typ.kind` and `result.` finds `result.add(`. Rows are
## tried widest first, because a suggestion that agrees with four tokens of
## what is already there is worth more than one that agrees with one. When
## there is a name being typed, plain words keep the last rows, since a phrase
## beginning with a name implies the name but not the other way round; and when
## the caret is at the start of a line, with nothing to go on at all, what is
## offered is what tends to begin one.

import std/sets
import uirelays
import widgets/[synedit, wordindex]

const
  MaxRows* = 9
    ## Nine because `Ctrl+1` .. `Ctrl+9` is what takes a row, and a tenth row
    ## would be one nothing could accept. A layout that gives the panel fewer
    ## lines than this scrolls; the numbers stay put either way, so a row does
    ## not change key under the pointer.
  WordRoom = 2
    ## Rows kept back for plain words when there is a name being typed. A
    ## phrase that starts with a name implies the name, but not the other way
    ## round -- so without this, `addFloat(` and its friends could fill the
    ## panel and leave nowhere to take `addFloat` on its own.

type
  Row = object
    text: string
    start: int           ## what the row replaces: everything from here to the
                         ## caret. A phrase matched three tokens back reaches
                         ## further left than a word does, and each row knows
                         ## how far its own does.

  Prediction* = object
    ed: SynEdit          ## the panel is a listing, and a listing is text
    items: seq[Row]
    pre: string          ## the longest prefix `items` was looked up under
    at: int              ## the caret they were built for
    textVer: int         ## the buffer version they were built from
    version: int         ## the index version they were built from

proc initPrediction*(font: Font): Prediction =
  result = Prediction(ed: createSynEdit(font))
  # A suggestion is a name, not code: nothing to colorize, nothing to number.
  result.ed.lang = langNone
  # Every row acts on click, exactly like the tab list and the history panel.
  result.ed.setActionLines(0)

proc setFont*(p: var Prediction; f: Font) {.inline.} = p.ed.setFont f
proc `theme=`*(p: var Prediction; t: Theme) {.inline.} = p.ed.theme = t
proc rows*(p: Prediction): seq[string] =
  ## What the panel is offering, in the order it shows it -- row 1 first. Empty
  ## when it has nothing to offer, which is the one state it draws a line of
  ## explanation in instead.
  result = @[]
  for it in p.items: result.add it.text
proc wheelScroll*(p: var Prediction; delta: int) {.inline.} =
  p.ed.wheelScroll delta

proc rebuildText(p: var Prediction; words: WordIndex) =
  var text = ""
  if p.items.len == 0:
    # A panel that is empty is a hole in the window, so the one state with
    # nothing to offer says what would fill it instead.
    text = if words.wordCount == 0:
             "nothing indexed yet -- try: index <path>"
           elif p.pre.len > 0:
             "nothing continues '" & p.pre & "'"
           else:
             "type, and this says what could come next"
  else:
    for i, it in p.items:
      if i > 0: text.add "\n"
      text.add $(i + 1)
      text.add ' '
      text.add it.text
  # A row is framed because it can be clicked; the line of explanation cannot,
  # so it is not framed and does not invite the click it would ignore.
  p.ed.setActionLines(if p.items.len == 0: -1 else: 0)
  p.ed.setText(text)
  p.ed.gotoLine(1, 0)
  # `setText` counts as an edit; saying so here is what lets `update` tell a
  # rebuild apart from someone typing into the panel.
  p.ed.markSaved()

proc refill(p: var Prediction; words: var WordIndex; ed: SynEdit) =
  p.version = words.version
  p.at = ed.cursor
  p.textVer = ed.textVersion
  p.items.setLen 0
  p.pre = ""
  var seen = initHashSet[string]()
  let word = ed.getWordPrefix
  # A phrase asked for with more tokens is a phrase that agrees with more of
  # what is already written, so the widest reach goes first. Asking for more
  # tokens than the line holds lands on the same place twice, which is what
  # `lastStart` notices.
  let room = if word.len > 0: MaxRows - WordRoom else: MaxRows
  var lastStart = -1
  for k in countdown(MaxPhraseTokens, 1):
    if p.items.len >= room: break
    let span = spanPrefix(ed, k)
    if span.start == lastStart or span.text.len == 0: continue
    lastStart = span.start
    let pre = normalizeSpan(span.text)
    if p.pre.len == 0: p.pre = pre
    for t in words.completePhrases(pre, limit = room):
      if seen.containsOrIncl(t): continue
      p.items.add Row(text: t, start: span.start)
      if p.items.len >= room: break
  if word.len > 0:
    if p.pre.len == 0: p.pre = word
    # One more than fits, because an exact hit is dropped: offering the word
    # that is already written is a row spent saying nothing.
    for w in words.complete(word, limit = MaxRows + 1):
      if w == word or seen.containsOrIncl(w): continue
      p.items.add Row(text: w, start: ed.cursor - word.len)
      if p.items.len >= MaxRows: break
  elif p.items.len == 0:
    # Nothing at all in front of the caret on this line. What is left to go on
    # is what tends to begin one.
    for t in words.completeInitial(limit = MaxRows):
      p.items.add Row(text: t, start: ed.cursor)
  p.rebuildText(words)

proc update*(p: var Prediction; words: var WordIndex; ed: SynEdit) =
  ## Bring the panel in line with where the caret is. Called every frame: it
  ## looks things up again only when the caret, the text or the index moved,
  ## so a frame in which nothing happened costs three integer compares.
  if ed.cursor != p.at or ed.textVersion != p.textVer or
     words.version != p.version:
    p.refill(words, ed)
  elif p.ed.changed:
    # Someone typed into the panel. It is a listing, not a buffer, so put back
    # what it is supposed to say.
    p.rebuildText(words)

proc accept*(p: var Prediction; row: int; ed: var SynEdit): bool =
  ## Take row `row`, counting from 1 as the panel does. False when there is no
  ## such row, so the caller can leave the keystroke alone.
  if row < 1 or row > p.items.len: return false
  let it = p.items[row - 1]
  ed.replaceSpan(it.start, it.text)
  result = true

proc draw*(p: var Prediction; e: Event; area: Rect; focused: bool): int =
  ## Draw the panel and report the row a click activated, counting from 1, or
  ## 0 for no click. The caret is never here, so `focused` only decides who
  ## gets the wheel and the click -- there is nothing to type.
  result = 0
  let act = p.ed.draw(e, area, focused)
  if focused and e.kind == MouseDownEvent and act.kind != closeLine:
    let row = p.ed.currentLine + 1
    if row <= p.items.len: result = row
