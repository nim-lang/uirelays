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
## The file format is NIF, without a header, so it can be read with the same
## lexer as the config:
##
##   (words
##     (source "/usr/local/nimony/lib")
##     (w abs add addFloat align))
##
## Words are written as bare NIF idents when they are one, and as string
## literals when they are not -- `[]=` and `=destroy` are perfectly good Nim
## names and neither is a NIF ident.

import std/[algorithm, os, sets]
# Only these two, by name: `strutils` has a `Letters` of its own, and the one
# that matters here is SynEdit's -- the set of characters a word is made of.
from std/strutils import toLowerAscii, startsWith
import ../uirelays/tinynif
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
# Scanning text for words
# ---------------------------------------------------------------------------

const
  MinWordLen* = 2
    ## A single letter is faster to type than to pick from a list, and `i` and
    ## `x` would sit at the top of every listing.

proc isWordStart(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '_', '\128'..'\255'}

proc scanWords*(text: string; dest: var WordBag; skipAround = -1) =
  ## Every identifier in `text`, in the order it occurs. A token that starts
  ## with a digit is not a word at all -- that keeps `0xffff` from becoming
  ## one. The word containing `skipAround` is left out: that is where the
  ## cursor is, and a half-typed name must not turn up as its own completion.
  var i = 0
  while i < text.len:
    if isWordStart(text[i]):
      let start = i
      while i < text.len and text[i] in Letters: inc i
      if i - start >= MinWordLen and
         not (skipAround >= start and skipAround <= i):
        dest.add text[start ..< i]
    elif text[i] in {'0'..'9'}:
      # A number, with whatever letters stick to it: `0xffff`, `1e9`, `3u8`.
      inc i
      while i < text.len and text[i] in Letters: inc i
    else:
      inc i

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
    ## Words that came from one place and can be forgotten as one.
    name*: string        ## what was indexed -- a directory, or a file
    words*: seq[string]

  WordIndex* = object
    sets*: seq[WordSet]  ## indexed paths and loaded lists
    live: WordBag        ## words from the open buffers
    merged: WordBag
    sorted: bool
    version*: int        ## bumped whenever a word was added or dropped, so a
                         ## listing built from this can tell that it is stale

proc addWord(idx: var WordIndex; w: string; live: bool) =
  if live: idx.live.add w
  if idx.merged.add(w):
    idx.sorted = false
    inc idx.version

proc rebuild(idx: var WordIndex) =
  idx.merged.clear()
  for s in idx.sets:
    for w in s.words: idx.merged.add w
  for w in idx.live.words: idx.merged.add w
  idx.sorted = false
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
  var left = lines
  var i = st.pos
  let cursor = s.cursor
  let n = s.len
  while i < n:
    let c = s[i]
    if c == '\L':
      dec left
      if left <= 0:
        st.pos = i + 1
        return true
      inc i
    elif isWordStart(c):
      let start = i
      while i < n and s[i] in Letters: inc i
      if i - start >= MinWordLen and not (cursor >= start and cursor <= i):
        var w = newStringOfCap(i - start)
        for j in start ..< i: w.add s[j]
        idx.addWord(w, live = true)
    elif c in {'0'..'9'}:
      inc i
      while i < n and s[i] in Letters: inc i
    else:
      inc i
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
  for w in idx.merged.words:
    if w.startsWith(prefix):
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

# ---------------------------------------------------------------------------
# Reading and writing a word list
# ---------------------------------------------------------------------------

proc isNifIdent(w: string): bool =
  ## Would this word lex back as a single `tkIdent`? Everything else has to be
  ## quoted.
  if w.len == 0: return false
  if w[0] in {'0'..'9', '-', '+', ':', '#'}: return false
  for c in w:
    if c in {'\0', ' ', '\t', '\r', '\n', '(', ')', '"', '\'', '.'}: return false
  result = true

proc nifString(s: string): string =
  ## A NIF string literal. NIF knows one escape -- a backslash and two hex
  ## digits -- so that is what everything unprintable becomes.
  const Hex = "0123456789ABCDEF"
  result = "\""
  for c in s:
    if c == '"' or c == '\\' or c < ' ' or c > '~':
      result.add '\\'
      result.add Hex[ord(c) shr 4]
      result.add Hex[ord(c) and 0xf]
    else:
      result.add c
  result.add '"'

proc nifWord(w: string): string =
  if w.isNifIdent: w else: nifString(w)

proc toNif*(s: WordSet): string =
  ## The set as a NIF file. Sorted, one long `(w ...)` wrapped at a readable
  ## width, so that re-indexing a directory produces a diff of what actually
  ## changed rather than of everything.
  var words = s.words
  sort words
  result = "# focim word list -- see doc/completion.md\n(words\n  (source " &
           nifString(s.name) & ")\n  (w"
  var col = 4
  for w in words:
    let t = nifWord(w)
    if col + t.len + 1 > 78:
      result.add "\n   "
      col = 3
    result.add ' '
    result.add t
    col += t.len + 1
  result.add "))\n"

proc parseWordSet*(text: string; s: var WordSet): string =
  ## Read what `toNif` wrote. Returns "" or "line:col: why". Nothing raises:
  ## a word list is a cache, and a broken one must not keep the editor from
  ## starting.
  s = WordSet(name: "", words: @[])
  var lex = initLexer(text)
  var tok = next(lex)
  if tok.kind != tkParLe or tok.text != "words":
    return tok.position & ": expected (words ...) but found " & $tok
  tok = next(lex)
  while tok.kind == tkParLe:
    let tag = tok.text
    tok = next(lex)
    case tag
    of "source":
      if tok.kind notin {tkStringLit, tkIdent, tkSymbol}:
        return tok.position & ": expected the source as a string but found " & $tok
      s.name = tok.text
      tok = next(lex)
    of "w":
      while tok.kind in {tkIdent, tkSymbol, tkStringLit}:
        s.words.add tok.text
        tok = next(lex)
    else:
      # Something a later version writes: step over it, balanced, so that an
      # old editor can still read a new list.
      var depth = 0
      while true:
        if tok.kind == tkParLe: inc depth
        elif tok.kind == tkParRi:
          if depth == 0: break
          dec depth
        elif tok.kind in {tkEof, tkError}: break
        tok = next(lex)
    if tok.kind == tkError: return tok.position & ": " & tok.text
    if tok.kind != tkParRi:
      return tok.position & ": expected ')' after (" & tag & " but found " & $tok
    tok = next(lex)
  if tok.kind == tkError: return tok.position & ": " & tok.text
  if tok.kind != tkParRi:
    return tok.position & ": expected ')' or a section but found " & $tok
  result = ""

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
        scanWords(readFile(path), job.bag)
    except CatchableError:
      inc job.skipped
  job.active = job.pending.len > 0
  result = job.active

proc doneIndexJob*(job: IndexJob): WordSet =
  WordSet(name: job.name, words: job.bag.words)

proc progress*(job: IndexJob): string =
  ## What to put in a status bar while the job runs.
  let done = job.total - job.pending.len
  result = "indexing " & job.name & ": " & $done & "/" & $job.total & " files"
