## Search and replace over a SynEdit buffer -- ported from nimedit's
## `editor/finder.nim`.
##
## A search is done once and leaves a list of hits behind, with a finger on one
## of them: `next` moves the finger, a replace consumes the hit under it and
## moves the ones after it by what the replacement made longer or shorter. So
## walking a hundred matches costs one scan, and replacing them one by one
## never rescans either.
##
## The hits belong to the text they were found in, and any edit that this
## module did not make invalidates them -- `stale` is what says so, and the
## application drops them rather than pointing at positions that have moved.
##
## Options are the letters nimedit used, in the same spelling: `i` ignore case
## (the default), `c` / `p` precise, `w` / `b` whole words, `s` not, `f` this
## file only. What nimedit called `y` (ignore style) is `i` here: its search
## never skipped underscores either, so the two were the same thing under two
## names. There is no regular expression option; nimedit's was compiled out.

from std/strutils import toLowerAscii
import synedit
from ../uirelays/screen import Color   ## what `mark` paints a hit with

export synedit

const Letters = {'a'..'z', 'A'..'Z', '0'..'9', '_', '\128'..'\255'}
  ## What a word is made of, for `wordBoundary`. Bytes above 127 count: a
  ## letter outside ASCII is part of the word it sits in, whatever it is.

type
  SearchOption* = enum
    ignoreCase        ## `i`, and what a search does unless `c` says otherwise
    wordBoundary      ## `w`: the hit may not sit inside a longer word
    currentFileOnly   ## `f`: `findall` / `replaceall` stay in this buffer
  SearchOptions* = set[SearchOption]

  SearchHit* = object
    a*, b*: int          ## the matched range, both ends inclusive
    replacement*: string ## what a replace puts there; "" deletes the hit

  BufferSearch* = object
    ## What one buffer knows about the last search. Kept next to the buffer
    ## rather than in the search: every buffer has its own hits, and a `next`
    ## that walks into another one has to find them there.
    hits*: seq[SearchHit]
    active*: int         ## the hit the finger is on; `hits.len` when past the end
    version: int         ## the text version `hits` were found in

proc parseSearchOptions*(s: string): SearchOptions =
  result = {ignoreCase}
  for c in s:
    case c
    of 'i', 'I', 'y', 'Y': result.incl ignoreCase
    of 'w', 'W', 'b', 'B': result.incl wordBoundary
    of 's', 'S': result.excl wordBoundary
    of 'p', 'P', 'c', 'C': result.excl ignoreCase
    of 'f', 'F': result.incl currentFileOnly
    else: discard

proc conv(c: char; opts: SearchOptions): char {.inline.} =
  if ignoreCase in opts: c.toLowerAscii else: c

proc findHits*(ed: SynEdit; term: string; opts: SearchOptions;
               replacement = ""): seq[SearchHit] =
  ## Every occurrence of `term`, left to right. Matches do not overlap: what
  ## follows a hit is looked for behind it, so `aa` in `aaa` is one hit and a
  ## replace cannot eat its own output.
  result = @[]
  if term.len == 0: return
  # A single letter is looked for as a word, always: `f i` is meant to find the
  # variable, and every third character in the file would not be an answer.
  let opts = opts + (if term.len == 1 and term[0] in Letters: {wordBoundary}
                     else: {})
  var i = 0
  while i + term.len <= ed.len:
    var k = 0
    while k < term.len and conv(term[k], opts) == conv(ed[i + k], opts): inc k
    if k < term.len:
      inc i
      continue
    let last = i + term.len - 1
    if wordBoundary notin opts or
       ((i == 0 or ed[i - 1] notin Letters) and
        (last + 1 >= ed.len or ed[last + 1] notin Letters)):
      result.add SearchHit(a: i, b: last, replacement: replacement)
    i = last + 1

proc run*(bs: var BufferSearch; ed: SynEdit; term: string; opts: SearchOptions;
          replacement = "") =
  ## Search `ed` and put the finger on the first hit at or after the cursor --
  ## a search starts where one is looking, not at the top of the file.
  bs.hits = findHits(ed, term, opts, replacement)
  bs.version = ed.textVersion
  bs.active = 0
  for j in 0 ..< bs.hits.len:
    if bs.hits[j].a >= ed.cursor:
      bs.active = j
      break

proc clear*(bs: var BufferSearch) =
  bs.hits.setLen 0
  bs.active = 0
  bs.version = 0

proc stale*(bs: BufferSearch; ed: SynEdit): bool =
  ## The buffer was edited by something other than a replace, so every hit
  ## after the edit is off by however much it moved.
  bs.hits.len > 0 and bs.version != ed.textVersion

proc step*(bs: var BufferSearch; backwards: bool): bool =
  ## Move the finger one hit along. False when that would leave the list --
  ## the caller answers that with another buffer, or by wrapping around.
  if bs.hits.len == 0: return false
  let n = bs.active + (if backwards: -1 else: 1)
  if n < 0 or n >= bs.hits.len: return false
  bs.active = n
  result = true

proc done*(bs: BufferSearch): bool =
  ## The finger is past the last hit: this buffer has nothing left to answer
  ## for. A buffer without hits is done before it starts.
  bs.active >= bs.hits.len

proc skipActive*(bs: var BufferSearch) =
  ## Leave the hit under the finger where it is and move past it -- what "no"
  ## does in a replace exchange.
  if bs.active < bs.hits.len: inc bs.active

proc rewind*(bs: var BufferSearch; toLast: bool) =
  ## Put the finger on the first hit, or on the last one for a search that is
  ## walking backwards.
  bs.active = if toLast: max(0, bs.hits.high) else: 0

proc gotoActive*(bs: BufferSearch; ed: var SynEdit) =
  ## Bring the hit under the finger into view, with the caret behind it -- so
  ## that typing replaces nothing and a following search carries on from here.
  if bs.active < bs.hits.len:
    ed.gotoPos(bs.hits[bs.active].b + 1)

proc replaceActive*(bs: var BufferSearch; ed: var SynEdit): bool =
  ## Swap the hit under the finger for its replacement and drop it from the
  ## list. The hits behind it move by the difference in length, so the rest of
  ## the search survives its own edit. False when there is nothing left to do.
  if bs.active >= bs.hits.len or bs.stale(ed): return false
  let m = bs.hits[bs.active]
  ed.replaceRange(m.a, m.b, m.replacement)
  bs.hits.delete bs.active
  let diff = m.replacement.len - (m.b - m.a + 1)
  if diff != 0:
    for i in bs.active ..< bs.hits.len:
      bs.hits[i].a += diff
      bs.hits[i].b += diff
  # The edit was this module's own, so the remaining hits are still right.
  bs.version = ed.textVersion
  result = true

proc mark*(bs: BufferSearch; ed: var SynEdit; hitBg, activeBg: Color) =
  ## Paint the hits. The one under the finger goes in first: a position that
  ## two markers cover takes the color of the one that was added first.
  ed.clearMarkers()
  if bs.active < bs.hits.len:
    ed.addMarker(bs.hits[bs.active].a, bs.hits[bs.active].b, activeBg)
  for i, h in bs.hits:
    if i != bs.active: ed.addMarker(h.a, h.b, hitBg)
