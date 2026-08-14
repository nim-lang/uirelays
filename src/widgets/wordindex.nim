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
## The file is a text file: the first line says where the words came from and
## every line after it is one word.
##
##   /usr/local/nimony/lib
##   abs
##   add
##   addFloat
##
## A list of words wants to be a list of words. Nothing about it needs a
## syntax -- there is no nesting, no attribute, and nothing to quote, since a
## word never contains a space or a newline. `[]=` and `=destroy` are perfectly
## good Nim names and both are simply themselves on a line of their own, which
## is not true of any format with an escape in it.

import std/[algorithm, os, sets]
# Only these three, by name: `strutils` has a `Letters` of its own, and the one
# that matters here is SynEdit's -- the set of characters a word is made of.
from std/strutils import toLowerAscii, startsWith, splitLines, strip
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

const
  MaxCharLit = 8
    ## `'\255'` is the longest character literal there is. A quote with more
    ## than this behind it is not one.

proc charLitEnd(text: string; j, n: int): int =
  ## Just past the character literal at `j` -- `'A'`, `'\n'`, `'\255'` -- or
  ## -1 when that quote begins something else. Skipping one whole is what
  ## keeps `xAB` out of the index when somebody writes `'\xAB'`.
  var k = j + 1
  if k < n and text[k] == '\\':
    inc k
    if k < n and text[k] != '\L': inc k
  while k < n and k - j <= MaxCharLit and text[k] notin {'\'', '\L'}: inc k
  result = if k < n and text[k] == '\'' and k > j + 1: k + 1 else: -1

proc scanWords*(text: string; dest: var WordBag; skipAround = -1) =
  ## Every identifier in `text`, in the order it occurs. A token that starts
  ## with a digit is not a word at all -- that keeps `0xffff` from becoming
  ## one. The word containing `skipAround` is left out: that is where the
  ## cursor is, and a half-typed name must not turn up as its own completion.
  ##
  ## Nothing is taken out of a comment or a string literal. What is written
  ## there is English -- `because`, `otherwise`, `example` -- and a listing of
  ## identifiers with English in it is a listing nobody reads. It is not a
  ## small share either: half of what Nimony's standard library appeared to
  ## know was prose. This is a scanner and not a parser, so a raw string with a
  ## backslash in it is read wrong; what that costs is a word too many, once.
  var i = 0
  var inBlock = 0   ## 0 none, 1 `/* */`, 2 `#[ ]#`, 3 `""" """`
  let n = text.len
  template toEndOfLine() =
    while i < n and text[i] != '\L': inc i
  while i < n:
    let c = text[i]
    if inBlock == 1:
      if c == '*' and i + 1 < n and text[i+1] == '/': inBlock = 0; inc i, 2
      else: inc i
    elif inBlock == 2:
      if c == ']' and i + 1 < n and text[i+1] == '#': inBlock = 0; inc i, 2
      else: inc i
    elif inBlock == 3:
      if c == '"' and i + 2 < n and text[i+1] == '"' and text[i+2] == '"':
        inBlock = 0; inc i, 3
      else: inc i
    elif c == '#':
      if i + 1 < n and text[i+1] == '[': inBlock = 2; inc i, 2
      else: toEndOfLine()
    elif c == '/' and i + 1 < n and text[i+1] == '/':
      toEndOfLine()
    elif c == '/' and i + 1 < n and text[i+1] == '*':
      inBlock = 1; inc i, 2
    elif c == '"':
      if i + 2 < n and text[i+1] == '"' and text[i+2] == '"':
        inBlock = 3; inc i, 3
      else:
        inc i
        # A string that is never closed ends with its line: an editor holds
        # half-written code most of the time, and one apostrophe must not eat
        # the rest of the file.
        while i < n and text[i] notin {'"', '\L'}:
          if text[i] == '\\': inc i
          inc i
        if i < n and text[i] == '"': inc i
    elif c == '\'':
      let e = charLitEnd(text, i, n)
      i = if e > 0: e else: i + 1
    elif isWordStart(c):
      let start = i
      while i < n and text[i] in Letters: inc i
      if i - start >= MinWordLen and
         not (skipAround >= start and skipAround <= i):
        dest.add text[start ..< i]
    elif c in {'0'..'9'}:
      # A number, with whatever letters stick to it: `0xffff`, `1e9`, `3u8`,
      # and the type on the end of `1'u8`.
      inc i
      while i < n and text[i] in Letters: inc i
      if i + 1 < n and text[i] == '\'' and isWordStart(text[i+1]):
        inc i
        while i < n and text[i] in Letters: inc i
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

proc toText*(s: WordSet): string =
  ## The set as a file: where the words came from, then one word per line,
  ## sorted -- so that re-indexing a directory produces a diff of what actually
  ## changed rather than of everything.
  var words = s.words
  sort words
  result = newStringOfCap(words.len * 12 + s.name.len + 2)
  result.add s.name
  result.add '\n'
  for w in words:
    result.add w
    result.add '\n'

proc parseWordSet*(text: string): WordSet =
  ## Read what `toText` wrote, and anything close enough to it: blank lines
  ## are skipped and every line is stripped, so a list edited by hand reads
  ## the same as one written here. There is nothing in it that can fail to
  ## parse, which is the point -- a word list is a cache, and a cache must
  ## never be a reason the editor will not start.
  result = WordSet(name: "", words: @[])
  var first = true
  for line in text.splitLines:
    let w = line.strip
    if first:
      # Even an empty first line is the name: the file says nothing about
      # where it came from, and the caller fills that in.
      result.name = w
      first = false
    elif w.len > 0:
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
