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
## That makes it the right home for suggestions that are longer than a word --
## a construct spelled across a whole row is unreadable in a popup that sits on
## top of the line it would replace. This first version predicts from the word
## index all the same, which is what proves the interaction; what it does not
## have yet is anything to say when the caret is not behind a word, and that is
## what a notion of context is for.

import uirelays
import widgets/[synedit, wordindex]

const
  MaxRows* = 9
    ## Nine because `Ctrl+1` .. `Ctrl+9` is what takes a row, and a tenth row
    ## would be one nothing could accept. A layout that gives the panel fewer
    ## lines than this scrolls; the numbers stay put either way, so a row does
    ## not change key under the pointer.

type
  Prediction* = object
    ed: SynEdit          ## the panel is a listing, and a listing is text
    items: seq[string]
    pre: string          ## the prefix `items` was built for
    hasPre: bool         ## whether there was a prefix at all
    version: int         ## the index version it was built from

proc initPrediction*(font: Font): Prediction =
  result = Prediction(ed: createSynEdit(font))
  # A suggestion is a name, not code: nothing to colorize, nothing to number.
  result.ed.lang = langNone
  # Every row acts on click, exactly like the tab list and the history panel.
  result.ed.setActionLines(0)

proc setFont*(p: var Prediction; f: Font) {.inline.} = p.ed.setFont f
proc `theme=`*(p: var Prediction; t: Theme) {.inline.} = p.ed.theme = t
proc rows*(p: Prediction): seq[string] {.inline.} = p.items
  ## What the panel is offering, in the order it shows it -- row 1 first. Empty
  ## when it has nothing to offer, which is the one state it draws a line of
  ## explanation in instead.
proc wheelScroll*(p: var Prediction; delta: int) {.inline.} =
  p.ed.wheelScroll delta

proc rebuildText(p: var Prediction; words: WordIndex) =
  var text = ""
  if p.items.len == 0:
    # A panel that is empty is a hole in the window, so the one state with
    # nothing to offer says what would fill it instead.
    text = if words.wordCount == 0:
             "nothing indexed yet -- try: index <path>"
           elif p.hasPre:
             "nothing continues '" & p.pre & "'"
           else:
             "type a name to see what could continue it"
  else:
    for i, w in p.items:
      if i > 0: text.add "\n"
      text.add $(i + 1)
      text.add ' '
      text.add w
  # A row is framed because it can be clicked; the line of explanation cannot,
  # so it is not framed and does not invite the click it would ignore.
  p.ed.setActionLines(if p.items.len == 0: -1 else: 0)
  p.ed.setText(text)
  p.ed.gotoLine(1, 0)
  # `setText` counts as an edit; saying so here is what lets `update` tell a
  # rebuild apart from someone typing into the panel.
  p.ed.markSaved()

proc refill(p: var Prediction; words: var WordIndex; prefix: string;
            hasPre: bool) =
  p.pre = prefix
  p.hasPre = hasPre
  p.version = words.version
  p.items.setLen 0
  if hasPre:
    # One more than fits, because an exact hit is dropped below: offering the
    # word that is already written is a row spent saying nothing.
    for w in words.complete(prefix, limit = MaxRows + 1):
      if w != prefix:
        p.items.add w
        if p.items.len >= MaxRows: break
  p.rebuildText(words)

proc update*(p: var Prediction; words: var WordIndex; ed: SynEdit) =
  ## Bring the panel in line with where the caret is. Called every frame: the
  ## work happens only when the prefix or the index actually moved, so the
  ## common frame costs a string compare.
  let prefix = ed.getWordPrefix
  let hasPre = prefix.len > 0
  if prefix != p.pre or hasPre != p.hasPre or words.version != p.version:
    p.refill(words, prefix, hasPre)
  elif p.ed.changed:
    # Someone typed into the panel. It is a listing, not a buffer, so put back
    # what it is supposed to say.
    p.rebuildText(words)

proc accept*(p: var Prediction; row: int; ed: var SynEdit): bool =
  ## Take row `row`, counting from 1 as the panel does. False when there is no
  ## such row, so the caller can leave the keystroke alone.
  if row < 1 or row > p.items.len: return false
  ed.replaceWordPrefix(p.items[row - 1])
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
