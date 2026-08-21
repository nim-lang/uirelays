## track.nim -- "where is this name?", answered by the compiler.
##
## Ctrl+click on an identifier and something has to say where it was declared
## and where else it is used. That is a question only a compiler can answer, so
## this asks one: `nim track PROJECT --defusages:FILE,LINE,COL`, or the pair of
## queries nimony spells `--def` / `--usages`. Which of the two is asked, and
## by what name it is run, is `(track ...)` in the config.
##
## `dus` -- definition *and* usages in one answer -- is deliberate. An editor
## that had to choose between "go to declaration" and "find usages" would have
## to know which of them the click meant, and it cannot: the same click on the
## same name means the declaration when you are reading and the usages when you
## are refactoring. Asking for both and offering the list sidesteps the whole
## question. It also sidesteps a second one -- a forward declaration makes even
## "go to declaration" ambiguous, so a single answer was never on the table:
##
##     proc twice(s: string): string        # <- a declaration
##     proc twice(s: string): string = s & s  # <- and so is this
##
## The compiler runs in a thread, because a project of any size takes seconds
## to answer and a window that stops for seconds is broken. `start` posts the
## query, `update` picks the answer up, and in between the editor is an editor.
##
## Nothing here raises: a compiler that is not installed, a project file that
## cannot be found and a query that matches nothing all end up in `note`.

import std/[os, osproc, streams, strutils]
import ../widgets/config

export config.Compiler, config.Track, config.defaultTrack, config.exeName

type
  TrackHit* = object
    ## One place the name is. `line` is 1-based and `col` counts bytes from 0,
    ## which is how every compiler in this file states a position -- and what
    ## `SynEdit.gotoLineBytes` takes.
    isDef*: bool
    name*: string
    path*: string
    line*, col*: int

  Tracker* = object
    busy*: bool        ## a query is out; a second click has to wait
    word*: string      ## the identifier the running query is about
    hits*: seq[TrackHit]
    ready*: bool       ## `hits` is an answer the host has not taken yet
    note*: string      ## why there is no answer, when there is none
    project*: string   ## the main module the running query was asked about

# ---------------------------------------------------------------------------
# Finding the project file
# ---------------------------------------------------------------------------

proc findProjectFile*(file: string): string =
  ## The main module of the project `file` belongs to -- what nimsuggest's
  ## `--find` computes, ported from the compiler's `findProjectNimFile`.
  ##
  ## Walking up from the file's own directory, a directory that holds a
  ## `.nimble`, `.nims`, `.cfg` or `.nimcfg` beside a `.nim` of the same name
  ## names the project. `<pkg>.nimble` wins over anything else in the same
  ## directory, since it is the file that says what the package is called, and
  ## a second `.nimble` in one directory gives up rather than guess. A nimble
  ## package whose source sits in a subdirectory is covered by looking for the
  ## name in the directory we came up from as well.
  ##
  ## "" when there is nothing to find: the caller then falls back to the file
  ## itself, which is the right project for a standalone script.
  const extensions = [".nims", ".cfg", ".nimcfg", ".nimble"]
  var
    candidates: seq[string] = @[]
    dir = file.parentDir
    prev = dir
    nimblepkg = ""
  let pkgname = dir.lastPathPart
  while true:
    try:
      for k, f in os.walkDir(dir, relative = true):
        if k == pcFile and f != "config.nims":
          let (_, name, ext) = splitFile(f)
          if ext in extensions:
            let x = changeFileExt(dir / name, ".nim")
            if fileExists(x):
              candidates.add x
            if ext == ".nimble":
              if nimblepkg.len == 0:
                nimblepkg = name
                # A nimble package may keep its source in a subdirectory, so
                # the directory we came up from is worth a look as well.
                if dir != prev:
                  let y = prev / x.extractFilename
                  if fileExists(y):
                    candidates.add y
              else:
                # More than one .nimble in a directory means we have most
                # likely walked past the real project, or that the package is
                # not one. Either way, guessing is worse than saying nothing.
                return ""
    except OSError:
      discard
    let want = if nimblepkg.len > 0: nimblepkg else: pkgname
    for c in candidates:
      if want in c.extractFilename: return c
    if candidates.len > 0:
      return candidates[0]
    prev = dir
    dir = dir.parentDir
    if dir.len == 0: break
  result = ""

# ---------------------------------------------------------------------------
# Reading what a compiler answered
# ---------------------------------------------------------------------------

proc allDigits(s: string; value: var int): bool =
  ## Only the digits, and at least one of them: `strutils.parseInt` would take
  ## a sign and raise on the rest, and neither is wanted in a field that has to
  ## decide whether it *is* a number.
  if s.len == 0: return false
  value = 0
  for c in s:
    if c notin {'0'..'9'}: return false
    value = value * 10 + (ord(c) - ord('0'))
  result = true

proc identOf(mangled: string): string =
  ## The name as it is written in the source. Nim reports it that way already;
  ## nimony reports the mangled `ident.disambiguator.module`, whose first run
  ## is the identifier -- and an operator, having no dot in it, is itself.
  let d = mangled.find('.')
  result = if d < 0: mangled else: mangled[0 ..< d]

proc hitFrom(line: string; base: string; dest: var TrackHit): bool =
  ## One line of a compiler's answer. Both compilers write a tab-separated
  ## record that starts with `def` or `use` -- and then part company: nim has
  ## a symbol kind and a trailing doc and quality field where nimony has
  ## neither, so the *position* of the file name differs between them. Rather
  ## than keep two layouts in step with two compilers, the record is read for
  ## the shape every version of it has: a non-empty field followed by two
  ## fields that are numbers is the file, the line and the column.
  ##
  ## `base` resolves a relative path, which nimony writes.
  result = false
  # `nim track` prints its progress to stderr, and a merged stream can leave a
  # run of dots in front of the first record. The record starts where `def` or
  # `use` does, and nothing in front of it can contain a tab.
  var start = -1
  for tag in ["def\t", "use\t"]:
    let i = line.find(tag)
    if i >= 0 and (start < 0 or i < start) and line.find('\t') >= i:
      start = i
  if start < 0: return
  let fields = line[start .. ^1].split('\t')
  if fields.len < 4: return
  var ln, col = 0
  for i in 1 .. fields.len - 3:
    if fields[i].len > 0 and allDigits(fields[i + 1], ln) and
       allDigits(fields[i + 2], col):
      dest = TrackHit(isDef: fields[0] == "def",
                      name: identOf(fields[2]),
                      path: (if isAbsolute(fields[i]): fields[i]
                             else: base / fields[i]),
                      line: ln, col: col)
      return true

proc parseHits*(output, base: string): seq[TrackHit] =
  ## Every record in `output`, in the order the compiler wrote them.
  result = @[]
  for line in output.splitLines:
    var h = default(TrackHit)
    if hitFrom(line, base, h): result.add h

proc `<`(a, b: TrackHit): bool =
  ## Declarations first -- that is what the click most often meant -- and
  ## within each group by where the text is, so the list reads like the files
  ## do rather than like the compiler's walk over them.
  if a.isDef != b.isDef: return a.isDef
  if a.path != b.path: return a.path < b.path
  if a.line != b.line: return a.line < b.line
  result = a.col < b.col

proc tidy*(hits: seq[TrackHit]): seq[TrackHit] =
  ## Sort, and drop what is the same place twice. A declaration is also a
  ## mention of the name, so both compilers report the declaration site as a
  ## usage as well; one row per place is what a list to pick from wants, and
  ## `<` has already put the declaration in front of its own echo.
  var sorted = hits
  # Insertion sort: a handful of hits is the normal case and a few hundred the
  # worst one, which is not worth a second algorithm.
  for i in 1 ..< sorted.len:
    let x = sorted[i]
    var j = i - 1
    while j >= 0 and x < sorted[j]:
      sorted[j + 1] = sorted[j]
      dec j
    sorted[j + 1] = x
  result = @[]
  for h in sorted:
    var dup = false
    for r in result:
      if r.path == h.path and r.line == h.line and r.col == h.col:
        dup = true
        break
    if not dup: result.add h

# ---------------------------------------------------------------------------
# The compiler, in a thread of its own
# ---------------------------------------------------------------------------

type
  Query = object
    exe: string
    dir: string             ## where to run it
    runs: seq[seq[string]]  ## one or more invocations; their output is joined

  Answer = object
    output: string          ## everything the runs printed
    failed: bool
    msg: string             ## why, when `failed`

var queries: Channel[Query]
var answers: Channel[Answer]
queries.open()
answers.open()

proc runOne(exe, dir: string; args: seq[string]; output: var string;
            msg: var string): bool =
  ## One invocation, read to the end. `poStdErrToStdOut` because the two
  ## streams have to be drained together or the child blocks on the one nobody
  ## is reading; the records are picked out of the mixture by `hitFrom`, and
  ## whatever else came along is what a failure gets explained by.
  result = false
  try:
    let p = startProcess(exe, dir, args,
                         options = {poUsePath, poStdErrToStdOut})
    output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      # The last thing it said before giving up is the useful part; the rest is
      # the hints it printed on the way there.
      for line in output.splitLines:
        let s = line.strip
        if s.len > 0: msg = s
      if msg.len == 0: msg = exe & " exited with " & $code
      return false
    result = true
  except CatchableError:
    # A compiler that is not installed lands here, which is the one failure
    # worth spelling out: the rest already said what they were.
    msg = getCurrentExceptionMsg()

proc trackThreadProc() {.thread.} =
  while true:
    let q = queries.recv()
    var a = Answer()
    for args in q.runs:
      var chunk = ""
      var msg = ""
      if runOne(q.exe, q.dir, args, chunk, msg):
        a.output.add chunk
      else:
        a.failed = true
        a.msg = msg
        break
    answers.send a

var trackThread: Thread[void]
var threadStarted = false

# ---------------------------------------------------------------------------
# The query
# ---------------------------------------------------------------------------

proc queryFor(t: Track; project, file: string;
              line, col: int): seq[seq[string]] =
  ## The command line for one lookup. Nim answers a definition and every usage
  ## in one go and counts columns from zero; nimony has a switch per half and
  ## counts them from one, so it is asked twice -- the second run is nearly
  ## free, since the first one left the nifcache built.
  let nimAt = file & "," & $line & "," & $col
  let nimonyAt = file & "," & $line & "," & $(col + 1)
  case t.compiler
  of compilerNone:
    result = @[]
  of compilerNim:
    result = @[@["track", project, "--defusages:" & nimAt]]
  of compilerNimony:
    result = @[@["check", project, "--def:" & nimonyAt],
               @["check", project, "--usages:" & nimonyAt]]

proc start*(t: var Tracker; spec: Track; file: string; line, col: int;
            word: string): bool =
  ## Ask where `word` -- the identifier at `line`:`col` of `file` -- is. False,
  ## with `note` saying why, when there was nothing to ask or nobody to ask.
  ## True means the answer arrives at some later `update`.
  result = false
  if spec.compiler == compilerNone:
    t.note = "tracking is off; (track (compiler \"nim\")) turns it on"
    return
  if t.busy:
    t.note = "still looking for '" & t.word & "'"
    return
  if file.len == 0:
    t.note = "save the file first -- a compiler needs a file to read"
    return
  var project = findProjectFile(file)
  if project.len == 0:
    # A file that belongs to no project is its own: that is exactly what a
    # standalone script is, and compiling it is what an editor would do too.
    project = file
  let runs = queryFor(spec, project, file, line, col)
  if runs.len == 0: return
  if not threadStarted:
    # Started on the first question rather than on startup: an editor that is
    # never asked one should not be carrying a thread around.
    threadStarted = true
    createThread[void](trackThread, trackThreadProc)
  t.hits.setLen 0
  t.ready = false
  t.busy = true
  t.word = word
  t.project = project
  t.note = "looking for '" & word & "' in " & project.extractFilename & " ..."
  queries.send Query(exe: spec.exeName, dir: project.parentDir, runs: runs)
  result = true

proc update*(t: var Tracker) =
  ## Pick up an answer if one has arrived. Nothing blocks: a query that is
  ## still running simply is not there yet.
  if not t.busy: return
  let (got, a) = answers.tryRecv()
  if not got: return
  t.busy = false
  if a.failed:
    t.note = a.msg
    return
  t.hits = tidy(parseHits(a.output, t.project.parentDir))
  t.ready = t.hits.len > 0
  if t.hits.len == 0:
    t.note = "nothing found for '" & t.word & "'"
  else:
    t.note = ""
