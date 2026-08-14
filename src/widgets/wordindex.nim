## wordindex.nim -- the words an editor can complete, and where they come from.
##
## Completion here is deliberately not semantic: there is no compiler in the
## loop, and nothing knows that `add` is a proc or that it takes two arguments.
## What there is, is a set of words that provably occur *somewhere* -- in the
## buffers that are open, in a directory that was indexed, in a list that was
## shipped -- so that a name never has to be typed twice, and a name that was
## never written anywhere is never offered.
##
## Three producers, one store:
##
## * `indexSlice` walks the open buffers a couple of hundred lines at a time,
##   picking up every identifier as it is typed.
## * `IndexJob` reads a directory tree, a few files per frame, and ends as a
##   `WordSet` that can be written out and read back.
## * `parseWordSet` reads such a file -- which is how the Nimony vocabulary
##   ships with the editor rather than being re-derived on every start.
##
## Beside the words are phrases -- runs of two to five tokens that somebody
## wrote more than once, in more than one file. A word saves the rest of a
## name; a phrase saves the rest of a construct, which is worth more per
## keystroke and is the reason `case ` can offer `case typ.kind`. Nothing about
## that is semantic either: it is still only what exists, counted.
##
## Both come out of one lexer, in one pass, and so does the text in front of
## the caret that a phrase is looked up under (`spanPrefix`). They have to
## agree about what a token is, or a prefix would reach a different distance
## into the line than the phrase it is meant to find; and none of the three
## takes anything out of a comment or a string literal.
##
## The file is a text file: the first line says where all of it came from, then
## one word per line, then one phrase per line with two numbers in front of it
## -- how often it was seen, and how often it began a line.
##
##   /usr/local/nimony/lib
##   abs
##   add
##   addFloat
##   31 12 result.add
##   9 9 case typ.kind
##
## A list like this wants no syntax. There is no nesting, no attribute and
## nothing to quote: a word never contains a space or a newline, and a phrase
## never contains a newline and always begins with a name -- so a leading
## integer can only ever be a count, and `[]=` and `=destroy` are simply
## themselves on a line of their own, which is not true of any format with an
## escape in it.

import std/[algorithm, os, sets, tables]
# Only these, by name: `strutils` has a `Letters` of its own, and the one that
# matters here is SynEdit's -- the set of characters a word is made of.
from std/strutils import toLowerAscii, startsWith, splitLines, strip,
                         parseInt, allCharsInSet, Digits
import synedit

# ---------------------------------------------------------------------------
# A bag of words: unique, insertion order, no ceremony
# ---------------------------------------------------------------------------

type
  WordBag* = object
    words*: seq[string]
    seen: HashSet[string]

proc add*(b: var WordBag; w: string): bool {.discardable.} =
  ## True when the word was not in the bag yet.
  if w in b.seen: return false
  b.seen.incl w
  b.words.add w
  result = true

proc len*(b: WordBag): int {.inline.} = b.words.len
proc contains*(b: WordBag; w: string): bool {.inline.} = w in b.seen

proc clear*(b: var WordBag) =
  b.words.setLen 0
  b.seen.clear()

# ---------------------------------------------------------------------------
# Phrases: several tokens in a row, exactly as somebody wrote them
# ---------------------------------------------------------------------------
#
# A word saves the rest of a name. A phrase saves the rest of a construct, and
# that is worth more per keystroke -- but only if it is a construct somebody
# actually wrote, which is the same bargain the word index makes. So phrases
# are mined the same way words are: every run of two to `MaxPhraseTokens`
# tokens on one line becomes a candidate, and what recurs is kept.
#
# The text of a phrase is the source between its first and last token, with
# runs of whitespace collapsed. Nothing is re-spaced: the corpus is real code,
# so its spacing is already the spacing this language is written in, and any
# rule invented here would only be a worse version of that.

const
  MinPhraseTokens* = 2
  MaxPhraseTokens* = 5
    ## Five is what it takes to reach past the punctuation: `case typ.kind of`
    ## is four tokens once a dotted name counts as one, and `result.add x` is
    ## three.
  MaxPhraseLen* = 60
    ## A row of the panel, roughly. A suggestion nobody can read is a
    ## suggestion nobody takes.
  MinPhraseCount* = 2
    ## What it takes for a phrase off disk to be kept. Once is a line somebody
    ## wrote; twice is a way of writing. An open buffer is exempt -- the file
    ## being edited is the one corpus where everything counts.
  MinPhraseFiles* = 2
    ## And in how many files, when there is more than one. A line repeated
    ## three hundred times in a generated table is not three hundred people
    ## agreeing; two files that share a phrase is the smallest thing that is.
  MaxPhraseEntries* = 200_000
    ## What one indexing job may hold before it throws away everything it has
    ## seen only once. A tree big enough to hit this is a tree where a phrase
    ## that occurs once is noise anyway.

type
  Phrase* = object
    text*: string
    count*: int      ## how often it was seen
    initial*: int    ## how often it began a line -- what ranks a suggestion
                     ## made when the caret is at the start of one
    live*: bool      ## it came out of an open buffer rather than off disk

  Tally = tuple[count, initial, files, lastFile: int]

  CountBag* = object
    ## Phrases, how often each was seen, and in how many files. A `HashSet`
    ## cannot do this and a `seq` would be quadratic, so this is the one place
    ## a `Table` earns its keep.
    counts: Table[string, Tally]
    file: int            ## which file is being added to right now

proc len*(b: CountBag): int {.inline.} = b.counts.len

proc nextFile*(b: var CountBag) {.inline.} =
  ## Say that what follows comes from another file. What that buys is the
  ## difference between a phrase written in ten places and one written ten
  ## times in the same place -- `uint64x2(hi:` occurs 620 times in Nimony's
  ## standard library, all of them in one machine-written file, and counting
  ## alone cannot tell that from an idiom.
  inc b.file

proc add*(b: var CountBag; text: string; initial: bool; counting = true): bool
         {.discardable.} =
  ## True when the phrase was not in the bag yet. `counting = false` records
  ## presence only, which is what an open buffer wants: its walk restarts on
  ## every edit, so counting there would measure how often the buffer was
  ## walked rather than how often the phrase occurs in it.
  b.counts.withValue(text, v):
    if counting:
      inc v.count
      if initial: inc v.initial
      if v.lastFile != b.file:
        v.lastFile = b.file
        inc v.files
    return false
  do:
    b.counts[text] = (1, ord(initial), 1, b.file)
    return true

proc prune*(b: var CountBag; minCount: int) =
  ## Forget what has been seen fewer than `minCount` times. Called when a job
  ## grows past `MaxPhraseEntries`, and again at the end of one.
  var keep = initTable[string, Tally]()
  for text, v in b.counts:
    if v.count >= minCount: keep[text] = v
  b.counts = ensureMove keep

proc toPhrases*(b: CountBag; minCount = 1; minFiles = 1; live = false):
               seq[Phrase] =
  ## The bag as a list sorted by text, which is what a prefix is looked up in.
  result = @[]
  for text, v in b.counts:
    if v.count >= minCount and v.files >= minFiles:
      result.add Phrase(text: text, count: v.count, initial: v.initial,
                        live: live)
  sort(result, proc (a, b: Phrase): int = cmp(a.text, b.text))

proc normalizeSpan*(s: string): string =
  ## What a phrase looks like: one space where the source had any run of
  ## whitespace. Applied to both sides of a comparison, so that a line indented
  ## with tabs matches a phrase mined from one indented with spaces.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] in {' ', '\t', '\r'}:
      while i < s.len and s[i] in {' ', '\t', '\r'}: inc i
      result.add ' '
    else:
      result.add s[i]
      inc i

# ---------------------------------------------------------------------------
# The lexer -- one idea of what a token is
# ---------------------------------------------------------------------------
#
# Words and phrases come out of the same pass, because they have to agree about
# where a token begins. They also have to agree with the caret: what the panel
# looks a phrase up under is the text in front of the cursor, tokenized right
# here by `spanPrefix`, and a prefix that counted `'A'` as three tokens where
# the corpus counted it as one would reach a different distance than the phrase
# it is meant to find.

const
  MinWordLen* = 2
    ## A single letter is faster to type than to pick from a list, and `i` and
    ## `x` would sit at the top of every listing.
  OpChars = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.', '|',
             '=', '%', '&', '$', '@', '~', ':'}
  MaxCharLit = 8
    ## `'\255'` is the longest character literal there is. A quote with more
    ## than this behind it is not one, and is treated as the stray character it
    ## is rather than swallowing the rest of the line.

proc isWordStart(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '_', '\128'..'\255'}

type
  TokSpan = tuple[a, b: int]   ## [a, b) into the text being scanned

proc charLitEnd(text: string; j, lineEnd: int): int =
  ## Just past the character literal that begins at `j`, or -1 when that quote
  ## begins something else. One token, because `{'A'..'Z'}` is a thing people
  ## write and want written for them.
  var k = j + 1
  if k < lineEnd and text[k] == '\\':
    inc k, 2                   # the backslash and what it escapes
    while k < lineEnd and k - j <= MaxCharLit and text[k] in Digits: inc k
  else:
    inc k
  result = if k < lineEnd and text[k] == '\'': k + 1 else: -1

proc lexLine(text: string; start, lineEnd: int; toks: var seq[TokSpan];
             breaks: var seq[int]; inBlock: var int) =
  ## The tokens of one line, and the indices in `toks` where a comment or a
  ## string literal cut the line in two -- what is on either side of a literal
  ## are two runs of tokens, not one. `inBlock` carries a block comment or a
  ## triple-quoted string from one line to the next.
  toks.setLen 0
  breaks.setLen 0
  template wall() =
    if breaks.len == 0 or breaks[^1] != toks.len: breaks.add toks.len
  var j = start
  while j < lineEnd:
    let c = text[j]
    if inBlock == 1:
      if c == '*' and j + 1 < lineEnd and text[j+1] == '/': inBlock = 0; inc j, 2
      else: inc j
    elif inBlock == 2:
      if c == ']' and j + 1 < lineEnd and text[j+1] == '#': inBlock = 0; inc j, 2
      else: inc j
    elif inBlock == 3:
      if c == '"' and j + 2 < lineEnd and text[j+1] == '"' and text[j+2] == '"':
        inBlock = 0; inc j, 3
      else: inc j
    elif c in {' ', '\t', '\r'}: inc j
    elif c == '#':
      wall()
      if j + 1 < lineEnd and text[j+1] == '[': inBlock = 2; inc j, 2
      else: j = lineEnd
    elif c == '/' and j + 1 < lineEnd and text[j+1] == '/':
      wall(); j = lineEnd
    elif c == '/' and j + 1 < lineEnd and text[j+1] == '*':
      wall(); inBlock = 1; inc j, 2
    elif c == '"':
      wall()
      if j + 2 < lineEnd and text[j+1] == '"' and text[j+2] == '"':
        inBlock = 3; inc j, 3
      else:
        inc j
        while j < lineEnd and text[j] != '"':
          if text[j] == '\\': inc j
          inc j
        if j < lineEnd: inc j
    elif c == '\'':
      let e = charLitEnd(text, j, lineEnd)
      if e > 0:
        toks.add (j, e)
        j = e
      else:
        # An unclosed quote is a character literal being typed, so it stays a
        # token: `{'A` has to keep matching `{'A'..'Z'}` while it is written.
        toks.add (j, j + 1)
        inc j
    elif isWordStart(c):
      let a = j
      while j < lineEnd and text[j] in Letters: inc j
      # A dotted name reads as one thing and so costs one token: `typ.kind` is
      # what somebody means, not three tokens they happened to write.
      while j + 1 < lineEnd and text[j] == '.' and isWordStart(text[j+1]):
        inc j
        while j < lineEnd and text[j] in Letters: inc j
      toks.add (a, j)
    elif c in Digits:
      let a = j
      inc j
      while j < lineEnd and text[j] in Letters: inc j
      if j + 1 < lineEnd and text[j] == '.' and text[j+1] in Digits:
        inc j
        while j < lineEnd and text[j] in Letters: inc j
      # `1'u8` is a number with a type on it, not a number and a literal.
      if j + 1 < lineEnd and text[j] == '\'' and isWordStart(text[j+1]):
        inc j
        while j < lineEnd and text[j] in Letters: inc j
      toks.add (a, j)
    elif c in OpChars:
      let a = j
      while j < lineEnd and text[j] in OpChars: inc j
      toks.add (a, j)
    else:
      toks.add (j, j + 1)
      inc j

proc takeWords(text: string; a, b: int; dest: var WordBag; skipAround: int) =
  ## The names in one token: `typ.kind` is one token but two words.
  var i = a
  while i < b:
    if isWordStart(text[i]):
      let start = i
      while i < b and text[i] in Letters: inc i
      if i - start >= MinWordLen and
         not (skipAround >= start and skipAround <= i):
        dest.add text[start ..< i]
    else:
      inc i

proc emitWindows(text: string; toks: seq[TokSpan]; a, b: int;
                 dest: var CountBag; atLineStart, counting: bool) =
  for i in a ..< b:
    # Only a name may begin a phrase, and the same name a word index would
    # have taken. A phrase starting with a bracket is one nobody would type
    # their way to, and one starting with `x` or `T` is a suggestion offered
    # after a single keystroke to save a comma -- leaving both out halves the
    # bag, and makes a leading integer in the file unambiguously a count, since
    # no phrase can begin with a digit.
    if not isWordStart(text[toks[i].a]) or
       toks[i].b - toks[i].a < MinWordLen: continue
    for k in MinPhraseTokens .. MaxPhraseTokens:
      let last = i + k - 1
      if last >= b: break
      if toks[last].b - toks[i].a > MaxPhraseLen: break
      dest.add(normalizeSpan(text[toks[i].a ..< toks[last].b]),
               initial = atLineStart and i == a, counting = counting)

proc scanSource*(text: string; words: var WordBag; phrases: var CountBag;
                 skipAround = -1; counting = true;
                 wantWords = true; wantPhrases = true) =
  ## Everything the index takes out of a piece of source, in one pass: the
  ## identifiers, and every two-to-`MaxPhraseTokens` run of tokens on one line.
  ##
  ## Neither takes anything out of a comment or a string literal. The words in
  ## there are prose -- `because`, `otherwise`, `example` -- and a listing of
  ## identifiers with English in it is a listing nobody reads; a phrase
  ## reaching across one would carry a sentence with it, and would be two
  ## tokens with forty characters of message between them. This is a miner and
  ## not a parser: a raw string with a backslash in it is read wrong, and the
  ## phrase that comes of that occurs once and is dropped for it.
  ##
  ## `skipAround` is where the caret is. The word it is inside is left out --
  ## a half-typed name must not turn up as its own completion -- and so is the
  ## whole line it is on, because half a line is not a phrase.
  var i = 0
  var toks: seq[TokSpan] = @[]
  var breaks: seq[int] = @[]
  var inBlock = 0   ## 0 none, 1 `/* */`, 2 `#[ ]#`, 3 `""" """`
  let n = text.len
  while i < n:
    var lineEnd = i
    while lineEnd < n and text[lineEnd] != '\L': inc lineEnd
    lexLine(text, i, lineEnd, toks, breaks, inBlock)
    if wantWords:
      for t in toks:
        if isWordStart(text[t.a]): takeWords(text, t.a, t.b, words, skipAround)
    if wantPhrases and not (skipAround >= i and skipAround <= lineEnd):
      var a = 0
      var atLineStart = true
      for bi in 0 .. breaks.len:
        let b = if bi < breaks.len: breaks[bi] else: toks.len
        if b > a:
          emitWindows(text, toks, a, b, phrases, atLineStart, counting)
          atLineStart = false
        a = b
    i = lineEnd + 1

proc scanWords*(text: string; dest: var WordBag; skipAround = -1) =
  ## The identifiers in `text` alone -- see `scanSource`. A token that starts
  ## with a digit is not a word at all, which is what keeps `0xffff` out.
  var ignore = CountBag()
  scanSource(text, dest, ignore, skipAround, wantPhrases = false)

proc scanPhrases*(text: string; dest: var CountBag; skipAround = -1;
                  counting = true) =
  ## The token runs in `text` alone -- see `scanSource`.
  var ignore = WordBag()
  scanSource(text, ignore, dest, skipAround, counting, wantWords = false)

proc spanPrefix*(s: SynEdit; tokens: int): tuple[text: string; start: int] =
  ## The last `tokens` tokens in front of the cursor, verbatim, and the offset
  ## they begin at -- the text a multi-token completion completes. The spacing
  ## comes along as it was written, so this is what is in the buffer rather
  ## than a normalization of it.
  ##
  ## The line is tokenized by the very lexer the corpus was, so that asking for
  ## five tokens reaches exactly as far as a five-token phrase does. It stops
  ## at the start of the line, and at a comment or a string literal on it:
  ## there is nothing to predict inside a message, and `echo "a` asks for
  ## nothing. Asking for more tokens than there are is not an error -- it
  ## yields what there is.
  let cursor = s.cursor.int
  let lineStart = s.lineStartOffset
  var text = newStringOfCap(cursor - lineStart)
  for j in lineStart ..< cursor: text.add s[j]
  var toks: seq[TokSpan] = @[]
  var breaks: seq[int] = @[]
  var inBlock = 0
  lexLine(text, 0, text.len, toks, breaks, inBlock)
  let first = if breaks.len > 0: breaks[^1] else: 0
  let take = max(first, toks.len - tokens)
  result.start = if take < toks.len: lineStart + toks[take].a else: cursor
  result.text = newStringOfCap(cursor - result.start)
  for j in result.start - lineStart ..< text.len: result.text.add text[j]

# ---------------------------------------------------------------------------
# Indexing an open buffer, a slice at a time
# ---------------------------------------------------------------------------

type
  BufferIndexer* = object
    ## Where the walk through one buffer stands. Kept next to the buffer, not
    ## inside the index: a buffer that is edited has to be walked again, and
    ## only the buffer knows when that happened.
    version: int   ## the text version that is completely indexed
    walking: int   ## the version the walk in progress belongs to
    pos: int       ## the offset to pick it up at

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

proc stylePrefix*(word, prefix: string): bool =
  ## Does `word` start with `prefix` under Nim's rules for identifiers: the
  ## first character decides case, everything after it ignores case and
  ## underscores. So `add_float` is offered for `addF`, which is the whole
  ## point -- the two are one name to the compiler.
  if prefix.len == 0: return true
  if word.len == 0 or word[0] != prefix[0]: return false
  var i = 1
  var j = 1
  while true:
    while j < prefix.len and prefix[j] == '_': inc j
    if j >= prefix.len: return true
    while i < word.len and word[i] == '_': inc i
    if i >= word.len: return false
    if word[i].toLowerAscii != prefix[j].toLowerAscii: return false
    inc i
    inc j

proc containsIgnoreCase(word, part: string): bool =
  if part.len == 0: return true
  if part.len > word.len: return false
  for start in 0 .. word.len - part.len:
    var k = 0
    while k < part.len and word[start + k].toLowerAscii == part[k].toLowerAscii:
      inc k
    if k == part.len: return true
  result = false

# ---------------------------------------------------------------------------
# The index
# ---------------------------------------------------------------------------

type
  WordSet* = object
    ## What came from one place and can be forgotten as one.
    name*: string        ## what was indexed -- a directory, or a file
    words*: seq[string]
    phrases*: seq[Phrase]

  WordIndex* = object
    sets*: seq[WordSet]  ## indexed paths and loaded lists
    live: WordBag        ## words from the open buffers
    merged: WordBag
    sorted: bool
    stat: seq[Phrase]    ## the sets' phrases, merged and sorted by text
    statHead: seq[Phrase]   ## the best of them for the start of a line
    liveBag: CountBag    ## phrases from the open buffers
    livePhr: seq[Phrase] ## the above, sorted by text
    liveHead: seq[Phrase]
    liveDirty: bool
    version*: int        ## bumped whenever a word or phrase was added or
                         ## dropped, so a listing built from this can tell
                         ## that it is stale

proc addWord(idx: var WordIndex; w: string; live: bool) =
  if live: idx.live.add w
  if idx.merged.add(w):
    idx.sorted = false
    inc idx.version

const
  HeadRoom = 200
    ## How many line-starters are kept ready. Nine are ever shown, and the
    ## rest are the room the live ones need to push past the shipped ones.

proc byRank(a, b: Phrase): int =
  ## Live first, then what recurs, then alphabetically -- the last so that a
  ## listing does not reshuffle itself as counts drift.
  result = cmp(b.live.int, a.live.int)
  if result == 0: result = cmp(b.count, a.count)
  if result == 0: result = cmp(a.text, b.text)

proc byInitial(a, b: Phrase): int =
  result = cmp(b.initial, a.initial)
  if result == 0: result = cmp(a.text, b.text)

proc headOf(list: seq[Phrase]): seq[Phrase] =
  result = @[]
  for p in list:
    if p.initial > 0: result.add p
  sort(result, byInitial)
  if result.len > HeadRoom: result.setLen HeadRoom

proc rebuildPhrases(idx: var WordIndex) =
  ## The sets' phrases as one list. Only `addSet` and `dropSet` reach here --
  ## the open buffers keep a list of their own, so typing never pays for this.
  var all = initTable[string, tuple[count, initial: int]]()
  for s in idx.sets:
    for p in s.phrases:
      all.withValue(p.text, v):
        inc v.count, p.count
        inc v.initial, p.initial
      do:
        all[p.text] = (p.count, p.initial)
  idx.stat = @[]
  for text, v in all:
    idx.stat.add Phrase(text: text, count: v.count, initial: v.initial)
  sort(idx.stat, proc (a, b: Phrase): int = cmp(a.text, b.text))
  idx.statHead = headOf(idx.stat)

proc rebuild(idx: var WordIndex) =
  idx.merged.clear()
  for s in idx.sets:
    for w in s.words: idx.merged.add w
  for w in idx.live.words: idx.merged.add w
  idx.sorted = false
  idx.rebuildPhrases()
  inc idx.version

proc addSet*(idx: var WordIndex; s: WordSet) =
  ## Add a named set, replacing one of the same name. Replacing rather than
  ## merging is what makes indexing a directory a second time pick up the
  ## files that are gone.
  for i in 0 ..< idx.sets.len:
    if idx.sets[i].name == s.name:
      idx.sets[i] = s
      idx.rebuild()
      return
  idx.sets.add s
  for w in s.words: idx.addWord(w, live = false)
  if s.phrases.len > 0:
    idx.rebuildPhrases()
    inc idx.version

proc dropSet*(idx: var WordIndex; name: string): bool =
  ## Forget one set. Words it shared with another set stay, which is why this
  ## rebuilds instead of subtracting.
  for i in 0 ..< idx.sets.len:
    if idx.sets[i].name == name:
      idx.sets.delete i
      idx.rebuild()
      return true
  result = false

proc needsIndexing*(st: BufferIndexer; s: SynEdit): bool {.inline.} =
  ## Is there anything left to walk in this buffer? Asked before `indexSlice`
  ## by a host that wants to spend its slice on the buffer that needs it.
  st.version != s.textVersion

proc wordCount*(idx: WordIndex): int {.inline.} = idx.merged.len
proc liveCount*(idx: WordIndex): int {.inline.} = idx.live.len

proc indexSlice*(idx: var WordIndex; s: SynEdit; st: var BufferIndexer;
                 lines = 200): bool {.discardable.} =
  ## Index at most `lines` lines of `s`, continuing where the last call
  ## stopped. Returns true while there is more of this buffer to do. Splitting
  ## the walk this way is what keeps a large file from being felt: it costs a
  ## fraction of a frame and picks itself up on the next one, and a buffer
  ## that is being typed in restarts its walk without ever blocking a keystroke.
  if st.version == s.textVersion: return false
  if st.walking != s.textVersion:
    st.walking = s.textVersion
    st.pos = 0
  # Lift the slice out as one string and scan that, rather than walking the gap
  # buffer twice with two nearly identical loops. A couple of hundred lines is
  # a few kilobytes; the copy does not show up next to the scanning.
  let n = s.len
  var last = st.pos
  var left = lines
  while last < n and left > 0:
    if s[last] == '\L': dec left
    inc last
  var text = newStringOfCap(last - st.pos)
  for j in st.pos ..< last: text.add s[j]
  let cursor = s.cursor.int - st.pos
  var bag = WordBag()
  let before = idx.liveBag.len
  # Presence, not frequency: this walk starts over on every edit, so counting
  # here would measure how often the buffer was walked.
  scanSource(text, bag, idx.liveBag, skipAround = cursor, counting = false)
  for w in bag.words: idx.addWord(w, live = true)
  if idx.liveBag.len != before:
    idx.liveDirty = true
    inc idx.version
  if last < n:
    st.pos = last
    return true
  st.version = s.textVersion
  st.walking = 0
  st.pos = 0
  result = false

proc complete*(idx: var WordIndex; prefix: string; limit = 200): seq[string] =
  ## The words that could continue `prefix`, best first: what starts with it
  ## exactly, then what starts with it in Nim's spelling-insensitive sense,
  ## then what merely contains it. Alphabetical within each of the three, so
  ## the listing does not reshuffle itself as the index grows.
  result = @[]
  if idx.merged.len == 0: return
  if not idx.sorted:
    sort idx.merged.words
    idx.sorted = true
  if prefix.len == 0:
    for w in idx.merged.words:
      result.add w
      if result.len >= limit: return
    return
  # One pass per group rather than one pass with three tests: a group that the
  # limit is already full without is never computed, and the last of them --
  # the substring search -- is the expensive one. On a large index that is the
  # difference between a listing that appears and one that is waited for.
  #
  # The first group is split in two so that a name out of a buffer that is open
  # comes before one out of the shipped vocabulary. Alphabetical order alone
  # buried the name defined three lines up under five from the standard
  # library, which is the wrong way round: what is on screen is what is being
  # written about.
  for w in idx.merged.words:
    if w.startsWith(prefix) and w in idx.live:
      result.add w
      if result.len >= limit: return
  for w in idx.merged.words:
    if w.startsWith(prefix) and w notin idx.live:
      result.add w
      if result.len >= limit: return
  for w in idx.merged.words:
    if not w.startsWith(prefix) and stylePrefix(w, prefix):
      result.add w
      if result.len >= limit: return
  for w in idx.merged.words:
    if not w.startsWith(prefix) and not stylePrefix(w, prefix) and
       w.containsIgnoreCase(prefix):
      result.add w
      if result.len >= limit: return

proc materialize(idx: var WordIndex) =
  if not idx.liveDirty: return
  idx.livePhr = idx.liveBag.toPhrases(live = true)
  idx.liveHead = headOf(idx.livePhr)
  idx.liveDirty = false

proc collect(list: seq[Phrase]; prefix: string; dest: var seq[Phrase]) =
  ## The phrases that begin with `prefix` and say more than it does. The list
  ## is sorted by text, so this is a range and not a search: what a listing
  ## costs stops depending on how much has been indexed.
  var i = lowerBound(list, prefix,
                     proc (p: Phrase; key: string): int = cmp(p.text, key))
  while i < list.len and list[i].text.startsWith(prefix):
    if list[i].text.len > prefix.len: dest.add list[i]
    inc i

proc completePhrases*(idx: var WordIndex; prefix: string; limit = 20):
                     seq[string] =
  ## The token runs that could continue `prefix`, best first. `prefix` is
  ## matched literally, so it has to have been through `normalizeSpan` -- which
  ## is also what makes a trailing space meaningful: `case ` asks what follows
  ## the word, `case` asks what the word itself could still become.
  result = @[]
  if prefix.len == 0: return
  idx.materialize()
  var hits: seq[Phrase] = @[]
  collect(idx.livePhr, prefix, hits)
  collect(idx.stat, prefix, hits)
  # Mining every window at once produces chains -- `for i in`, `for i in 0`,
  # `for i in 0 ..<` -- and three rows that say nested things are two rows
  # wasted. A phrase whose extension was seen exactly as often as it was never
  # occurs on its own, so it says nothing the longer one does not; sorting by
  # text puts a phrase directly in front of its shortest extension, which is
  # what makes this the one comparison it takes to find out.
  sort(hits, proc (a, b: Phrase): int = cmp(a.text, b.text))
  var keep = newSeq[Phrase](0)
  for i in 0 ..< hits.len:
    if i + 1 < hits.len and hits[i+1].count == hits[i].count and
       hits[i+1].live == hits[i].live and
       hits[i+1].text.startsWith(hits[i].text):
      continue
    keep.add hits[i]
  sort(keep, byRank)
  var seen = initHashSet[string]()
  for p in keep:
    # Two rows that differ only in where the spaces are -- `0 ..< n` and
    # `0..<n` -- are one suggestion written twice, and the more common spelling
    # of it got here first.
    var squeezed = newStringOfCap(p.text.len)
    for c in p.text:
      if c != ' ': squeezed.add c
    if seen.containsOrIncl(squeezed): continue
    result.add p.text
    if result.len >= limit: return

proc completeInitial*(idx: var WordIndex; limit = 20): seq[string] =
  ## What could begin a line, for the caret that sits at the start of one and
  ## has told us nothing yet. Ranked by how often each did begin one, which is
  ## the only thing there is to go on when there is no prefix at all.
  result = @[]
  idx.materialize()
  var seen = initHashSet[string]()
  for list in [idx.liveHead, idx.statHead]:
    for p in list:
      if seen.containsOrIncl(p.text): continue
      result.add p.text
      if result.len >= limit: return

proc phraseCount*(idx: var WordIndex): int =
  idx.materialize()
  idx.stat.len + idx.livePhr.len

# ---------------------------------------------------------------------------
# Reading and writing a word list
# ---------------------------------------------------------------------------

proc toText*(s: WordSet): string =
  ## The set as a file: where it came from, then the words one per line, then
  ## the phrases. Each of the two runs is sorted, so that re-indexing a
  ## directory produces a diff of what actually changed rather than of
  ## everything.
  ##
  ## A phrase line carries two numbers in front of it -- how often it was seen
  ## and how often it began a line -- and a word line carries none. Nothing has
  ## to say which is which, because a phrase always begins with a name and so
  ## can never begin with a digit.
  var words = s.words
  sort words
  var phrases = s.phrases
  sort(phrases, proc (a, b: Phrase): int = cmp(a.text, b.text))
  result = newStringOfCap(words.len * 12 + phrases.len * 24 + s.name.len + 2)
  result.add s.name
  result.add '\n'
  for w in words:
    result.add w
    result.add '\n'
  for p in phrases:
    result.add $p.count
    result.add ' '
    result.add $p.initial
    result.add ' '
    result.add p.text
    result.add '\n'

proc splitCounts(line: string): tuple[count, initial, at: int] =
  ## The two leading numbers of a phrase line, and where the phrase itself
  ## begins. `at = 0` when there are none, which is what a word line looks
  ## like. One number is accepted as well, so that a file somebody has edited
  ## by hand is still read the way it looks.
  result = (0, 0, 0)
  var i = 0
  var fields = 0
  while fields < 2:
    var j = i
    while j < line.len and line[j] in Digits: inc j
    if j == i or j >= line.len or line[j] != ' ': break
    let v = parseInt(line[i ..< j])
    if fields == 0: result.count = v else: result.initial = v
    inc fields
    i = j + 1
    result.at = i

proc parseWordSet*(text: string): WordSet =
  ## Read what `toText` wrote, and anything close enough to it: blank lines
  ## are skipped and every line is stripped, so a list edited by hand reads
  ## the same as one written here. There is nothing in it that can fail to
  ## parse, which is the point -- a word list is a cache, and a cache must
  ## never be a reason the editor will not start.
  result = WordSet(name: "", words: @[], phrases: @[])
  var first = true
  for line in text.splitLines:
    let w = line.strip
    if first:
      # Even an empty first line is the name: the file says nothing about
      # where it came from, and the caller fills that in.
      result.name = w
      first = false
    elif w.len == 0:
      discard
    else:
      let (count, initial, at) = splitCounts(w)
      if at > 0 and at < w.len:
        result.phrases.add Phrase(text: w[at .. ^1], count: max(count, 1),
                                  initial: initial)
      else:
        result.words.add w

# ---------------------------------------------------------------------------
# Indexing a directory tree
# ---------------------------------------------------------------------------

const
  MaxIndexFiles* = 5000
    ## More than any project one edits, and little enough that pointing the
    ## command at a home directory by mistake stops instead of grinding.
  MaxIndexFileSize* = 1024 * 1024
    ## A megabyte of source is a generated file, and generated files are all
    ## the same word over and over.

type
  IndexJob* = object
    name*: string          ## the path being indexed
    pending*: seq[string]  ## files not read yet
    total*: int            ## how many there were to begin with
    skipped*: int          ## files too large, or unreadable
    truncated*: bool       ## the tree had more files than `MaxIndexFiles`
    bag*: WordBag
    phrases*: CountBag
    pruned*: bool          ## the bag grew past `MaxPhraseEntries` and what had
                           ## been seen once was thrown away to make room
    active*: bool

proc indexable(path: string): bool =
  ## Source, not prose: a word out of a paragraph of English is noise in a
  ## listing of identifiers.
  let lang = fileExtToLanguage(path.splitFile.ext.toLowerAscii)
  result = lang != langNone and lang != langMarkdown

proc collectFiles(root: string; dest: var seq[string]): bool =
  ## Every indexable file under `root`, dotted directories left alone. True
  ## when it stopped at `MaxIndexFiles`.
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    try:
      for kind, p in walkDir(dir):
        let name = p.extractFilename
        if name.len == 0 or name[0] == '.': continue
        case kind
        of pcDir, pcLinkToDir:
          if name != "nimcache" and name != "node_modules": stack.add p
        else:
          if indexable(p):
            if dest.len >= MaxIndexFiles: return true
            dest.add p
    except CatchableError:
      discard
  result = false

proc startIndexJob*(path: string): IndexJob =
  ## Prepare to index a file or a directory tree. The walk happens here -- it
  ## is the reading that is slow, and that is what `stepIndexJob` spreads out.
  result = IndexJob(name: path, pending: @[], active: true)
  if fileExists(path):
    if indexable(path): result.pending.add path
  elif dirExists(path):
    result.truncated = collectFiles(path, result.pending)
  result.total = result.pending.len
  result.active = result.pending.len > 0

proc stepIndexJob*(job: var IndexJob; files = 8): bool {.discardable.} =
  ## Read up to `files` of them. True while the job has more to do.
  var n = files
  while n > 0 and job.pending.len > 0:
    let path = job.pending.pop()
    dec n
    try:
      if getFileSize(path) > MaxIndexFileSize:
        inc job.skipped
      else:
        let text = readFile(path)
        job.phrases.nextFile()
        scanSource(text, job.bag, job.phrases)
    except CatchableError:
      inc job.skipped
  if job.phrases.len > MaxPhraseEntries:
    job.phrases.prune(MinPhraseCount)
    job.pruned = true
  job.active = job.pending.len > 0
  result = job.active

proc doneIndexJob*(job: IndexJob): WordSet =
  ## Only what recurred: a phrase seen once in a whole tree is a line somebody
  ## wrote, not a way of writing. In a tree it also has to have been written in
  ## two different files, which is what separates an idiom from a machine-
  ## written table of the same line -- and cannot be asked of a single file,
  ## since there the second file does not exist.
  WordSet(name: job.name, words: job.bag.words,
          phrases: job.phrases.toPhrases(
            minCount = MinPhraseCount,
            minFiles = if job.total > 1: MinPhraseFiles else: 1))

proc progress*(job: IndexJob): string =
  ## What to put in a status bar while the job runs.
  let done = job.total - job.pending.len
  result = "indexing " & job.name & ": " & $done & "/" & $job.total & " files"
