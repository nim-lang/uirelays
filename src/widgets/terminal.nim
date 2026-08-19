## Terminal -- command console widget for uirelays.
##
## Ported from nimedit's console component. Wraps a SynEdit in
## ``langConsole`` mode and adds command execution, history, and
## tab completion.
##
## Usage::
##
##   var term = createTerminal(font)
##   # in your main loop:
##   term.draw(e, rect(0, 0, 600, 400))
##
## The terminal runs commands in a background thread and streams
## their output into the editor buffer.

import std/[os, osproc, streams, strutils, tables, browsers]
when defined(windows): import std/winlean
else: import std/posix
import synedit
import ../uirelays/[coords, screen, input]

export synedit

# ---------------------------------------------------------------------------
# File filtering (for tab completion)
# ---------------------------------------------------------------------------

const
  ExtensionsToIgnore* = [
    ".ppu", ".o", ".obj", ".dcu",
    ".map", ".tds", ".err", ".bak", ".pyc", ".exe", ".rod", ".pdb", ".idb",
    ".idx", ".ilk", ".dll", ".so", ".a"
  ]

proc ignoreFile*(f: string): bool =
  ## Build output and backups: what nobody means when they name a file.
  let (_, name, ext) = f.splitFile
  result = name.len > 0 and name[0] == '.' or ext in ExtensionsToIgnore or
           f == "nimcache"

# ---------------------------------------------------------------------------
# Command history
# ---------------------------------------------------------------------------

type
  CmdHistory* = object
    cmds*: seq[string]
    suggested*: int

proc addCmd(h: var CmdHistory; cmd: string) =
  var replaceWith = -1
  for i in 0..high(h.cmds):
    if h.cmds[i] == cmd:
      swap(h.cmds[i], h.cmds[^1])
      h.suggested = h.cmds.high
      return
    elif h.cmds[i] in cmd:
      if replaceWith < 0 or h.cmds[replaceWith] < h.cmds[i]:
        replaceWith = i
  if replaceWith < 0:
    h.cmds.add cmd
  else:
    h.cmds[replaceWith] = cmd

proc suggest(h: var CmdHistory; up: bool): string =
  if h.suggested < 0 or h.suggested >= h.cmds.len:
    h.suggested = (if up: h.cmds.high else: 0)
  if h.suggested >= 0 and h.suggested < h.cmds.len:
    result = h.cmds[h.suggested]
    h.suggested += (if up: -1 else: 1)
  else:
    result = ""

# ---------------------------------------------------------------------------
# Command parsing helpers
# ---------------------------------------------------------------------------

proc handleHexChar(s: string; pos: int; xi: var int): int =
  case s[pos]
  of '0'..'9':
    xi = (xi shl 4) or (ord(s[pos]) - ord('0'))
    result = pos+1
  of 'a'..'f':
    xi = (xi shl 4) or (ord(s[pos]) - ord('a') + 10)
    result = pos+1
  of 'A'..'F':
    xi = (xi shl 4) or (ord(s[pos]) - ord('A') + 10)
    result = pos+1
  else: result = pos

proc parseEscape(s: string; w: var string; start: int): int =
  var pos = start + 1
  if pos >= s.len:
    w.add '\\'
    return pos
  case s[pos]
  of 'n', 'N': w.add "\n"; inc pos
  of 'r', 'R', 'c', 'C': w.add '\c'; inc pos
  of 'l', 'L': w.add '\L'; inc pos
  of 'f', 'F': w.add '\f'; inc pos
  of 'e', 'E': w.add '\e'; inc pos
  of 'a', 'A': w.add '\a'; inc pos
  of 'b', 'B': w.add '\b'; inc pos
  of 'v', 'V': w.add '\v'; inc pos
  of 't', 'T': w.add '\t'; inc pos
  of '\'', '"': w.add s[pos]; inc pos
  of '\\': w.add '\\'; inc pos
  of 'x', 'X':
    inc pos
    var xi = 0
    pos = handleHexChar(s, pos, xi)
    pos = handleHexChar(s, pos, xi)
    w.add char(xi and 0xFF)
  of '0'..'9':
    var xi = 0
    while pos < s.len and s[pos] in {'0'..'9'}:
      xi = (xi * 10) + (ord(s[pos]) - ord('0'))
      inc pos
    if xi <= 255: w.add char(xi)
  else:
    w.add '\\'
  result = pos

proc parseWord(s: string; w: var string; start = 0;
               convToLower = false): int =
  template conv(c: char): char =
    (if convToLower: c.toLowerAscii else: c)
  w.setLen 0
  var i = start
  while i < s.len and s[i] in {' ', '\t'}: inc i
  if i >= s.len: return i
  case s[i]
  of '\'':
    inc i
    while i < s.len:
      if s[i] == '\'':
        if i+1 < s.len and s[i+1] == '\'':
          w.add s[i]
          inc i
        else:
          inc i
          break
      else:
        w.add s[i].conv
      inc i
  of '"':
    inc i
    while i < s.len:
      if s[i] == '"':
        inc i
        break
      elif s[i] == '\\':
        i = parseEscape(s, w, i)
      else:
        w.add s[i].conv
        inc i
  else:
    while i < s.len and s[i] > ' ':
      w.add s[i].conv
      inc i
  result = i

proc cmdToArgs(cmd: string): tuple[exe: string, args: seq[string]] =
  result.exe = ""
  result.args = @[]
  var i = parseWord(cmd, result.exe, 0)
  while true:
    var x = ""
    i = parseWord(cmd, x, i)
    if x.len == 0: break
    result.args.add x

# ---------------------------------------------------------------------------
# Background process thread
# ---------------------------------------------------------------------------

type
  ThreadTask = object
    cwd: string
    cmd: string

  ThreadReply = object
    text: string     ## output to append, may end mid-line
    finished: bool   ## the process is over; nothing more will come

var requests: Channel[ThreadTask]
requests.open()
var responses: Channel[ThreadReply]
responses.open()

const EndToken = "\e"
  ## Only a *request*: asks the thread to terminate the running process.
  ## Replies say they are the last one with `ThreadReply.finished`, so no byte
  ## of a process's output can be mistaken for the end of it.

# Output is read from the pipe handle rather than through `p.outputStream`,
# which wraps it in a stdio `File` -- the wrong tool here twice over. Its reads
# go through `fread`, which does not return until it has a full block or the
# pipe closes, so on a live process the output only surfaced once it had
# exited. And the bytes stdio buffers are invisible to a readiness check on the
# file descriptor, so waiting and reading cannot be combined through it.

const OutputChunk = 4096

when defined(windows):
  proc waitForOutput(p: Process; timeoutMs: int): bool =
    ## `PeekNamedPipe` cannot wait, so poll it.
    var waited = 0
    while true:
      if osproc.hasData(p): return true
      if waited >= timeoutMs: return false
      os.sleep 10
      inc waited, 10

  proc readAvailable(p: Process; buf: var string): int =
    var got: int32 = 0
    if readFile(p.outputHandle.Handle, addr buf[0], int32(buf.len),
                addr got, nil) == 0:
      return 0     # broken pipe: end of output
    result = got.int
else:
  proc waitForOutput(p: Process; timeoutMs: int): bool =
    ## True as soon as the pipe holds something, or has reached its end. The
    ## timeout is what lets the loop notice a request that arrives while the
    ## process is quiet -- typed input, or Ctrl+C.
    var fds = default(TFdSet)
    FD_ZERO(fds)
    FD_SET(cint(p.outputHandle), fds)
    var tv = Timeval(tv_sec: posix.Time(timeoutMs div 1000),
                     tv_usec: Suseconds((timeoutMs mod 1000) * 1000))
    result = select(cint(p.outputHandle) + 1, addr fds, nil, nil, addr tv) == 1

  proc readAvailable(p: Process; buf: var string): int =
    result = posix.read(p.outputHandle, addr buf[0], buf.len)
    if result < 0: result = 0

proc execThreadProc() {.thread.} =
  var p: Process
  var started = false
  var chunk = newString(OutputChunk)

  template reap() =
    ## The process is over: report how it went and say this is the last reply.
    started = false
    let exitCode = p.waitForExit()
    p.close()
    if exitCode != 0:
      responses.send ThreadReply(
        text: "Process terminated with exitcode: " & $exitCode & "\L")
    responses.send ThreadReply(finished: true)

  while true:
    var tasks = requests.peek()
    if tasks == 0 and not started: tasks = 1
    if tasks > 0:
      for i in 0..<tasks:
        let task = requests.recv()
        if task.cmd == EndToken:
          if started:
            p.terminate()
            reap()
        else:
          if not started:
            let (bin, args) = cmdToArgs(task.cmd)
            try:
              p = startProcess(bin, task.cwd, args,
                        options = {poStdErrToStdOut, poUsePath, poInteractive,
                                   poDaemon})
              started = true
            except:
              started = false
              responses.send ThreadReply(text: getCurrentExceptionMsg())
              responses.send ThreadReply(finished: true)
          else:
            p.inputStream.writeLine task.cmd
            # Buffered: without this the process waits for input that is
            # already sitting in this end of the pipe.
            p.inputStream.flush()
    if started:
      # Hand over whatever has arrived so far, even a part of a line -- that is
      # what makes a progress indicator move rather than appear at the end.
      # The wait is bounded so that a request arriving while the process is
      # quiet still gets picked up on the next turn.
      if waitForOutput(p, 50):
        chunk.setLen OutputChunk
        let n = readAvailable(p, chunk)
        if n > 0:
          chunk.setLen n
          responses.send ThreadReply(text: chunk)
        else:
          reap()      # end of the pipe
      elif not p.running:
        reap()        # exited without closing the pipe (a child still holds it)

var backgroundThread: Thread[void]
createThread[void](backgroundThread, execThreadProc)

# ---------------------------------------------------------------------------
# Terminal type
# ---------------------------------------------------------------------------

type
  TermActionKind* = enum
    noAction,
    openFile,           ## user typed `o <file>` / `open <file>`
    saveFile,           ## user typed `save` / `s [<file>]`
    searchText,         ## user typed `find` / `findall` / `replace` / `replaceall`
    gotoMatch,          ## user typed `next` / `prev`
    answer,             ## a line typed while `question` was up
    indexWords,         ## user typed `index <path>` or `unindex <path>`
    resetConfig,        ## user typed `defaults`
    ctrlHover,          ## ctrl+mouse move over text
    ctrlClick           ## ctrl+click on text

  TermAction* = object
    case kind*: TermActionKind
    of noAction: discard
    of openFile, saveFile:
      file*: string     ## `arg` resolved against `base`; "" when nothing was
                        ## typed, which for `save` means "where it came from"
      arg*: string      ## as typed, for a host that wants to look for it
                        ## somewhere else as well
    of searchText:
      term*: string     ## what to look for; "" asks for the last search to be
                        ## forgotten rather than for a search
      replacement*: string  ## what to put there; only a `replace` has one
      opts*: string     ## the option letters, uninterpreted -- what they mean
                        ## is the host's business
      replacing*: bool  ## `replace` / `replaceall` rather than a plain find
      allBuffers*: bool ## `findall` / `replaceall` rather than this one
    of gotoMatch:
      backwards*: bool  ## `prev` rather than `next`
    of answer:
      word*: string     ## the first word of the line, lower case
    of indexWords:
      path*: string     ## absolute; "" asks what is indexed rather than
                        ## indexing anything
      forget*: bool     ## `unindex`: drop the set instead of adding it
    of resetConfig: discard
    of ctrlHover, ctrlClick:
      pos*: int         ## buffer offset

  Terminal* = object
    ed*: SynEdit
    hist*: Table[string, CmdHistory]
    ran*: seq[string]   ## commands run since the host last emptied this.
                        ## `Enter` is handled inside `draw`, so without this a
                        ## host cannot tell that a command happened -- which it
                        ## needs to keep a history list of its own.
    files: seq[string]
    prefix: string
    processRunning*: bool
    beforeSuggestionPos: int
    aliases*: seq[(string, string)]
    process: string
    cwd*: string
    question*: string   ## what the host is waiting to hear, "" when it is not
                        ## waiting for anything. While this is set, a line
                        ## typed here comes back as an `answer` instead of
                        ## being run -- which is what keeps `yes` and `no`
                        ## from having to become commands, shadowing the
                        ## programs of those names.
                        ##
                        ## For a widget used as an application's *prompt*,
                        ## like `baseDir` above: a prompt is a line one
                        ## answers in, and a terminal is where programs run,
                        ## so a host that has both leaves this one empty. The
                        ## host also shows the text -- a prompt rewrites its
                        ## own line, so the widget has nowhere to put it.
    baseDir*: string    ## what a relative path in `o` / `save` is resolved
                        ## against. "" means `cwd`, which is what a terminal
                        ## wants: it has a current directory of its own and a
                        ## `cd` to move it with. A widget used as an
                        ## application's prompt has neither, and points this at
                        ## whatever the application considers current.
    isPrompt*: bool     ## whether this widget is an application's prompt
                        ## rather than a place programs run in. It changes one
                        ## thing: a command that acts on the application
                        ## itself, rather than on a file or on the machine, is
                        ## only a command here. In a terminal the same word is
                        ## a program's name, which is where it belongs -- see
                        ## `defaults` below.
    branch: string      ## cached result of `gitBranch`; see `insertPrompt`
    branchDir: string   ## the directory `branch` was read for. Anything else,
                        ## "" included, means the cache says nothing about the
                        ## current `cwd` -- which is also the starting state,
                        ## and what a `cd` restores.

proc base*(t: Terminal): string =
  ## The directory a relative path typed here is taken to be relative to.
  if t.baseDir.len > 0: t.baseDir else: t.cwd

proc resolve*(t: Terminal; path: string): string =
  ## `path` as typed, made absolute. "" stays "": nothing was typed, and a
  ## command that got no path must not end up with the base directory itself.
  let e = expandTilde(path)
  if e.len == 0: ""
  elif isAbsolute(e): e
  else: t.base / e

proc getCommand(t: Terminal): string =
  result = ""
  for i in t.ed.readOnly + 1 ..< t.ed.len:
    result.add t.ed[i]

proc emptyCmd(t: var Terminal) =
  while true:
    if t.ed.len - 1 <= t.ed.readOnly: break
    t.ed.backspace(smartIndent = false)

# ---------------------------------------------------------------------------
# Git branch in the prompt
# ---------------------------------------------------------------------------

proc gitDirOf(startDir: string): string =
  ## The git directory of the repository `startDir` sits in, or "". Walks up
  ## the tree: work happens in a subdirectory of a checkout far more often than
  ## at its root, and a prompt that forgot the branch after `cd src` would be
  ## more confusing than one that never showed it.
  var dir = normalizedPath(if startDir.len > 0: startDir else: ".")
  while true:
    let candidate = dir / ".git"
    if dirExists(candidate):
      return candidate
    if fileExists(candidate):
      # A linked worktree or a submodule: the file names the real git directory.
      const marker = "gitdir:"
      var contents = ""
      try: contents = readFile(candidate).strip
      except CatchableError: return ""
      if not contents.startsWith(marker): return ""
      result = contents[marker.len .. ^1].strip
      if not result.isAbsolute: result = normalizedPath(dir / result)
      return
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir: return ""
    dir = parent

proc gitBranch*(dir: string): string =
  ## The branch checked out in the repository `dir` belongs to, or "" when it is
  ## not a checkout. A detached HEAD reads as its short commit hash.
  ##
  ## Reads `.git/HEAD` rather than running `git`: this sits on the path of every
  ## prompt, and spawning a process there would be felt on every command.
  let gitDir = gitDirOf(dir)
  if gitDir.len == 0: return ""
  var head = ""
  try:
    head = readFile(gitDir / "HEAD").strip
  except CatchableError:
    return ""
  const refMarker = "ref: "
  if head.startsWith(refMarker):
    let refName = head[refMarker.len .. ^1].strip
    const branchMarker = "refs/heads/"
    # `refs/heads/topic` is a branch; anything else keeps its last component,
    # which is the best short name it has.
    result =
      if refName.startsWith(branchMarker): refName[branchMarker.len .. ^1]
      else: refName.lastPathPart
  elif head.len >= 7 and head.allCharsInSet(HexDigits):
    result = head[0 ..< 7]

proc mentionsCd*(cmd: string): bool =
  ## Whether `cd` occurs in `cmd` as a word: `cd ..` and `mkdir x && cd x` do,
  ## `cdrom` and `abcd` do not. A word character is what could be part of a
  ## command name, so `/bin/cd` still counts.
  const WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  var i = 0
  while true:
    let at = cmd.find("cd", i)
    if at < 0: return false
    let after = at + 2
    if (at == 0 or cmd[at - 1] notin WordChars) and
       (after >= cmd.len or cmd[after] notin WordChars):
      return true
    i = at + 1

proc insertPrompt*(t: var Terminal) =
  ## The branch is cached: without that, `.git/HEAD` would be read again after
  ## every single command, and only a `cd` can move this terminal into another
  ## checkout. `runCommand` drops the cache when it sees one.
  ##
  ## The cache remembers *which* directory it read, because `cwd` is a public
  ## field: a host that sets it directly never goes through `runCommand`, and
  ## would otherwise get the previous checkout's branch next to the new path.
  if t.branchDir != t.cwd:
    t.branch = gitBranch(t.cwd)
    t.branchDir = t.cwd
  if t.branch.len > 0:
    t.ed.appendOutput(t.cwd & " [" & t.branch & "]>")
  else:
    t.ed.appendOutput(t.cwd & ">")

# ---------------------------------------------------------------------------
# Tab completion
# ---------------------------------------------------------------------------

proc startsWithIgnoreCase(s, prefix: string): bool =
  var i = 0
  while true:
    if i >= prefix.len: return true
    if i >= s.len: return false
    if s[i].toLowerAscii != prefix[i].toLowerAscii: return false
    inc i

proc addFile(t: var Terminal; path: string) =
  if find(path, {' ', '\t'}) >= 0:
    t.files.add path.escape
  else:
    t.files.add path

proc suggestPath(t: var Terminal; prefix: string) =
  var sug = -1
  if prefix.len > 0:
    for i, x in t.files:
      if x.extractFilename.startsWithIgnoreCase(prefix) and not x.ignoreFile:
        sug = i
        break
  if sug < 0 and prefix.len > 0:
    let p = prefix.toLowerAscii
    for i, x in t.files:
      if p in x.toLowerAscii and not x.ignoreFile:
        sug = i
        break
  if sug < 0 and prefix.len == 0:
    sug = 0
    while sug < t.files.high:
      if t.files[sug].ignoreFile: inc sug
      else: break
  if sug >=% t.files.len: return
  for i in 0..<t.beforeSuggestionPos:
    t.ed.backspace(smartIndent = false)
  t.ed.insertText(t.files[sug])
  t.beforeSuggestionPos = t.files[sug].len
  delete(t.files, sug)

proc tabPressed(t: var Terminal) =
  if t.ed.changed:
    let cmd = t.getCommand()
    t.prefix.setLen 0
    var prefixB = ""
    var i = 0
    while true:
      i = parseWord(cmd, prefixB, i)
      if prefixB.len == 0:
        if i > 0 and cmd[i-1] == ' ':
          t.prefix.setLen 0
        break
      swap(t.prefix, prefixB)
    t.beforeSuggestionPos = t.prefix.len
    t.files.setLen 0

  if t.files.len == 0:
    let (path, prefix) = t.prefix.splitPath
    if path.len > 0 and path[0] == '~':
      let expandedPath = getHomeDir() / path.substr(1)
      for k, f in os.walkDir(expandedPath, relative = false):
        t.addFile f
    elif t.prefix.isAbsolute:
      for k, f in os.walkDir(path, relative = false):
        t.addFile f
    else:
      # The same directory the command itself would be resolved against:
      # completing to a file that `o` then does not find would be a trap.
      for k, f in os.walkDir(t.base / path, relative = true):
        t.addFile path / f
    t.prefix = prefix
  t.suggestPath(t.prefix)

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

proc dirContents(t: var Terminal; ext: string) =
  var i = 0
  for k, f in os.walkDir(t.base, relative = true):
    if ext.len == 0 or cmpPaths(f.splitFile.ext, ext) == 0:
      t.ed.appendOutput(f)
      if i == 4:
        t.ed.appendOutput("\L")
        i = 0
      else:
        t.ed.appendOutput("    ")
      inc i
  t.ed.appendOutput("\L")

proc runCommand*(t: var Terminal; cmd: var string): TermAction =
  result = TermAction(kind: noAction)
  t.files.setLen 0
  if t.question.len > 0 and not t.processRunning:
    # This line answers what the host asked. It is not a command, and it is
    # not history either: what was typed is one word of an exchange, and the
    # exchange is over as soon as it is handed over.
    var word = ""
    discard parseWord(cmd, word, 0, convToLower = true)
    t.question.setLen 0
    t.ed.appendOutput "\L"
    t.insertPrompt()
    return TermAction(kind: answer, word: word)
  t.hist[t.process].addCmd(cmd)
  t.ran.add cmd
  if t.processRunning:
    requests.send(ThreadTask(cwd: t.cwd, cmd: cmd))
    return

  var a = ""
  var i = parseWord(cmd, a, 0, true)
  t.ed.appendOutput "\L"
  for al in t.aliases:
    if a == al[0]:
      cmd = al[1] & cmd.substr(i)
      i = parseWord(cmd, a, 0, true)
      break
  # After the aliases, so one that expands to a `cd` counts too. Only marks the
  # cache stale: the `cd` below has not moved `t.cwd` yet, and it is the prompt
  # that needs the answer. `cd .` therefore doubles as a way to pick up a branch
  # that changed behind this terminal's back.
  if mentionsCd(cmd): t.branchDir.setLen 0
  # The prompt's own command, and only its own: `defaults` puts the host's
  # config back, which is a thing to ask an application and not a thing to ask
  # a machine. In a terminal the word stays a program's name -- macOS has one
  # of exactly this name -- so it is not taken out of anybody's hands there.
  # What the config *is* remains the host's business; this only reports that
  # it was asked for.
  if t.isPrompt and a == "defaults":
    t.insertPrompt()
    return TermAction(kind: resetConfig)
  case a
  of "":
    t.insertPrompt()
  of "o", "open":
    # A program of that name is still reachable as `./open` or `/usr/bin/open`:
    # only the bare word is a command of this terminal's own.
    var b = ""
    i = parseWord(cmd, b, i)
    t.insertPrompt()
    result = TermAction(kind: openFile, file: t.resolve(b), arg: b)
  of "save", "s":
    # `save` writes the buffer back, `save <file>` writes it somewhere else.
    # What a name that is already taken means is the host's decision, and
    # `question` is how it gets to ask.
    var b = ""
    i = parseWord(cmd, b, i)
    t.insertPrompt()
    result = TermAction(kind: saveFile, file: t.resolve(b), arg: b)
  of "find", "f", "findall":
    # `find <term> [options]`. The term goes through `parseWord`, so one with
    # a space in it is written 'like this'.
    var term = ""
    i = parseWord(cmd, term, i)
    var opts = ""
    i = parseWord(cmd, opts, i)
    t.insertPrompt()
    result = TermAction(kind: searchText, term: term, opts: opts,
                        allBuffers: a == "findall")
  of "replace", "r", "replaceall":
    var term = ""
    i = parseWord(cmd, term, i)
    var with = ""
    i = parseWord(cmd, with, i)
    var opts = ""
    i = parseWord(cmd, opts, i)
    t.insertPrompt()
    result = TermAction(kind: searchText, term: term, replacement: with,
                        opts: opts, replacing: true,
                        allBuffers: a == "replaceall")
  of "next":
    t.insertPrompt()
    result = TermAction(kind: gotoMatch)
  of "prev", "v":
    t.insertPrompt()
    result = TermAction(kind: gotoMatch, backwards: true)
  of "index", "unindex":
    # Reported rather than done: what a word index is good for is the host's
    # business, and a terminal that grew one would have to grow a completion
    # popup to go with it.
    var b = ""
    i = parseWord(cmd, b, i)
    t.insertPrompt()
    result = TermAction(kind: indexWords, path: t.resolve(b),
                        forget: a == "unindex")
  of "cls":
    t.ed.clear()
    t.ed.lang = langConsole
    t.insertPrompt()
  of "cd":
    var b = ""
    i = parseWord(cmd, b, i)
    if b.len > 0:
      if isAbsolute(b):
        t.cwd = b
      else:
        t.cwd = t.cwd / b
    t.insertPrompt()
  of "d":
    var b = ""
    i = parseWord(cmd, b, i)
    t.dirContents(b)
    t.insertPrompt()
  else:
    if i >= cmd.len - 1 and (a.endsWith".html" or a.startsWith"http://" or
        a.startsWith"https://"):
      openDefaultBrowser(a)
    else:
      requests.send(ThreadTask(cwd: t.cwd, cmd: cmd))
      t.processRunning = true
      swap(t.process, cmd)
      if t.process notin t.hist:
        t.hist[t.process] = CmdHistory(cmds: @[], suggested: -1)

proc enterPressed(t: var Terminal): TermAction =
  var cmd = t.getCommand()
  result = t.runCommand(cmd)

# ---------------------------------------------------------------------------
# Update (poll background thread)
# ---------------------------------------------------------------------------

proc update*(t: var Terminal) =
  if t.processRunning:
    if responses.peek > 0:
      let resp = responses.recv()
      if resp.text.len > 0:
        t.ed.appendOutput(resp.text)
      if resp.finished:
        t.processRunning = false
        t.process.setLen 0
        t.ed.appendOutput "\L"
        t.insertPrompt()

proc sendBreak*(t: var Terminal) =
  if t.processRunning:
    requests.send(ThreadTask(cwd: "", cmd: EndToken))

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

proc createTerminal*(font: Font; theme = defaultTheme()): Terminal =
  result = Terminal(
    ed: createSynEdit(font, theme),
    hist: initTable[string, CmdHistory](),
    files: @[],
    prefix: "",
    aliases: @[],
    process: "",
    cwd: os.getCurrentDir())
  result.ed.lang = langConsole
  result.hist[""] = CmdHistory(cmds: @[], suggested: -1)
  result.insertPrompt()

# ---------------------------------------------------------------------------
# Drawing (immediate-mode: input + render)
# ---------------------------------------------------------------------------

proc draw*(t: var Terminal; e: Event; area: Rect; focused: bool): TermAction =
  ## Per-frame entry point. When focused, processes input and shows cursor.
  ## When not focused, just paints. Always polls for process output.
  result = TermAction(kind: noAction)
  t.update()

  if focused:
    # Ensure cursor is in the editable area so it's visible.
    if t.ed.cursor <= t.ed.readOnly:
      t.ed.gotoPos(t.ed.len)
    # Intercept terminal-specific keys before passing to SynEdit.
    if e.kind == KeyDownEvent:
      let ctrl = CtrlPressed in e.mods
      case e.key
      of KeyUp:
        if not ctrl:
          let sug = t.hist[t.process].suggest(up = true)
          if sug.len > 0:
            t.emptyCmd()
            t.ed.insertText(sug)
          t.ed.render(area, showCursor = true)
          return
      of KeyDown:
        if not ctrl:
          let sug = t.hist[t.process].suggest(up = false)
          if sug.len > 0:
            t.emptyCmd()
            t.ed.insertText(sug)
          t.ed.render(area, showCursor = true)
          return
      of KeyTab:
        t.tabPressed()
        t.ed.render(area, showCursor = true)
        return
      of KeyEnter:
        result = t.enterPressed()
        t.ed.render(area, showCursor = true)
        return
      of KeyC:
        if ctrl and t.processRunning:
          t.sendBreak()
          t.ed.render(area, showCursor = true)
          return
      else: discard

  let edAct = t.ed.draw(e, area, focused)
  case edAct.kind
  of ctrlHover:
    result = TermAction(kind: ctrlHover, pos: edAct.pos)
  of ctrlClick:
    result = TermAction(kind: ctrlClick, pos: edAct.pos)
  of noAction, closeLine: discard
