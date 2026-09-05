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

import std/[os, osproc, streams, strtabs, strutils, tables, times, browsers]
when defined(windows): import std/winlean
else: import std/posix
import synedit
import ansi
when defined(posix): import pty
import filesearch
import ../uirelays/[coords, screen, input]

export synedit
# What tab completion leaves out of a listing is what a file search leaves out
# of a tree -- build output and backups either way, so the rule lives in one
# place and both ask it.
export filesearch.ignoreFile, filesearch.ExtensionsToIgnore

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
    cols, rows: int   ## how wide and tall the panel is, in characters. A
                      ## program asks its terminal this before it decides
                      ## where to wrap, and answering 80x24 out of habit is
                      ## how output ends up folded somewhere other than the
                      ## edge it is being drawn against.

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

var forcedEnv {.threadvar.}: StringTableRef
  ## Built once, on the thread that spawns -- a `threadvar` because that is
  ## the thread that owns it, and a global would make every proc that touches
  ## it un-GC-safe.

proc panelEnv(): StringTableRef =
  ## The environment a command is run in.
  ##
  ## On a pty there is almost nothing to say: the program asks whether it is
  ## talking to a terminal, is told yes, and decides for itself to color and
  ## to decorate -- and it obeys the user's own configuration while doing it,
  ## which forcing `color.ui=always` down its throat did not.
  ##
  ## Two things still have to be said. `TERM`, because a terminal that does
  ## not name itself is assumed to be incapable of anything. And that there is
  ## to be no pager: `git log` on a terminal pipes itself through `less`, which
  ## would sit in the panel waiting for a keypress on a screen nobody can see.
  ## That is the one thing a pipe used to get right for free.
  if forcedEnv == nil:
    # Windows compares environment variable names without regard to case, so
    # a table that does not would answer "no" to `PATH` and add a second one.
    forcedEnv = newStringTable(
      when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
    for k, v in envPairs(): forcedEnv[k] = v
    template unless(key, value: string) =
      if not forcedEnv.hasKey(key): forcedEnv[key] = value
    when defined(posix):
      unless("TERM", "xterm-256color")
      # Not `unless`: a pager the user chose for their own terminal is exactly
      # what must not run in here.
      forcedEnv["PAGER"] = "cat"
      forcedEnv["GIT_PAGER"] = "cat"
    else:
      # No pty here, so the arguing stands: a program that finds a pipe turns
      # color off, and `git` turns its decorations off with it.
      unless("CLICOLOR_FORCE", "1")
      unless("FORCE_COLOR", "1")
      if not forcedEnv.hasKey("GIT_CONFIG_COUNT"):
        const gitConfig = [("color.ui", "always"), ("log.decorate", "short")]
        forcedEnv["GIT_CONFIG_COUNT"] = $gitConfig.len
        for i, (key, value) in gitConfig:
          forcedEnv["GIT_CONFIG_KEY_" & $i] = key
          forcedEnv["GIT_CONFIG_VALUE_" & $i] = value
  result = forcedEnv

proc execThreadProc() {.thread.} =
  when defined(posix):
    var p: Pty
  else:
    var p: Process
  var started = false
  var chunk = newString(OutputChunk)

  template reap() =
    ## The program is over: report how it went and say this is the last reply.
    started = false
    when defined(posix):
      let exitCode = p.close()
    else:
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
            when defined(posix):
              # A signal to the program in front, which is what Ctrl+C is. A
              # program that means to catch it gets the chance to, and one that
              # spawned others takes them with it.
              p.interrupt()
              # Give it a moment to go on its own before insisting.
              var waited = 0
              while p.running() and waited < 300:
                os.sleep 20
                inc waited, 20
              if p.running(): p.terminate()
            else:
              p.terminate()
            reap()
        else:
          if not started:
            let (bin, args) = cmdToArgs(task.cmd)
            when defined(posix):
              p = startPty(bin, args, task.cwd, panelEnv(),
                           max(task.cols, 20), max(task.rows, 4))
              started = p.alive
              if not started:
                responses.send ThreadReply(text: "cannot run: " & bin & "\L")
                responses.send ThreadReply(finished: true)
            else:
              try:
                p = startProcess(bin, task.cwd, args, env = panelEnv(),
                          options = {poStdErrToStdOut, poUsePath, poInteractive,
                                     poDaemon})
                started = true
              except:
                started = false
                responses.send ThreadReply(text: getCurrentExceptionMsg())
                responses.send ThreadReply(finished: true)
          else:
            when defined(posix):
              # The line goes to the terminal driver, which is what a program
              # waiting on one is waiting for.
              p.writeInput(task.cmd & "\L")
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
          reap()      # the far end has gone
      elif not p.running:
        reap()        # exited without closing it (a child still holds it)

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

  HeadStamp = tuple[written: times.Time; size: BiggestInt]
    ## What a `HEAD` file looks like from the outside -- enough to tell one
    ## that was rewritten from one that was not, without reading it.

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
    screen: TermScreen  ## the last few rows of what a program printed, still
                        ## open to being drawn on again -- the color in force,
                        ## an escape sequence the end of a chunk cut in half,
                        ## and where the program left its cursor. See
                        ## `showOutput`.
    liveStart: int      ## the buffer offset those rows begin at. Everything
                        ## before it is final; everything after is redrawn
                        ## whenever the program moves.
    cols, rows: int     ## the panel's size in characters, as last drawn, and
                        ## what a program starting here is told it has.
    branch: string      ## cached result of `gitBranch`; see `insertPrompt`
    branchDir: string   ## the directory `branch` was read for. Anything else,
                        ## "" included, means the cache says nothing about the
                        ## current `cwd` -- which is also the starting state,
                        ## and what a `cd` restores.
    headFile: string    ## the `HEAD` `branch` was read from, "" when
                        ## `branchDir` is no part of a checkout. Cached along
                        ## with it: finding it means a walk up the tree.
    headStamp: HeadStamp ## what that file looked like when it was read. A
                        ## `git checkout` rewrites it, which is how the prompt
                        ## notices a branch it did not switch itself.

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

proc endOutput(t: var Terminal) =
  ## The program is gone, so the rows it could still have drawn on cannot be
  ## drawn on any more. They stay where they are; what goes is the expectation
  ## that anything will come back to them.
  t.screen = initTermScreen()
  t.liveStart = t.ed.len

proc caretToEnd(t: var Terminal) =
  ## Put the caret back where typing goes. What a program printed is text like
  ## any other here -- the caret walks into it and a selection can be taken out
  ## of it -- but a key that *edits* belongs to the line being typed, so
  ## everything that edits comes through here first.
  if t.ed.cursor.int > t.ed.readOnly: return
  t.ed.deselect()
  t.ed.gotoPos(t.ed.len)

proc emptyCmd(t: var Terminal) =
  ## Take the typed command back off the line, wherever in it the caret is
  ## standing. Backspace is what deletes it, and backspace deletes in front of
  ## the caret, so the caret goes to the end first -- and if a character will
  ## not go after all, this stops instead of asking forever.
  t.ed.deselect()
  t.ed.gotoPos(t.ed.len)
  while t.ed.len - 1 > t.ed.readOnly:
    let before = t.ed.len
    t.ed.backspace(smartIndent = false)
    if t.ed.len >= before: break

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

proc headFileOf(dir: string): string =
  ## The `HEAD` that names the branch `dir` has checked out, or "" when `dir`
  ## is no part of a checkout.
  let gitDir = gitDirOf(dir)
  result = if gitDir.len == 0: "" else: gitDir / "HEAD"

proc stampOf(headFile: string): HeadStamp =
  ## `headFile` as `getFileInfo` sees it. "" and a file that is not there share
  ## the default stamp: neither of them names a branch, and neither changes
  ## into the other without a `cd` or a `git`, both of which drop the cache.
  if headFile.len == 0: return
  try:
    let info = getFileInfo(headFile)
    result = (written: info.lastWriteTime, size: info.size)
  except CatchableError:
    discard

proc branchOf(headFile: string): string =
  ## The branch `headFile` names, or "" when there is no such file. A detached
  ## HEAD reads as its short commit hash.
  if headFile.len == 0: return ""
  var head = ""
  try:
    head = readFile(headFile).strip
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

proc gitBranch*(dir: string): string =
  ## The branch checked out in the repository `dir` belongs to, or "" when it is
  ## not a checkout. A detached HEAD reads as its short commit hash.
  ##
  ## Reads `.git/HEAD` rather than running `git`: this sits on the path of every
  ## prompt, and spawning a process there would be felt on every command.
  branchOf(headFileOf(dir))

proc mentionsWord*(cmd, word: string): bool =
  ## Whether `word` occurs in `cmd` as a word: for `cd`, `cd ..` and
  ## `mkdir x && cd x` do, `cdrom` and `abcd` do not. A word character is what
  ## could be part of a command name, so `/bin/cd` still counts.
  const WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  if word.len == 0: return false
  var i = 0
  while true:
    let at = cmd.find(word, i)
    if at < 0: return false
    let after = at + word.len
    if (at == 0 or cmd[at - 1] notin WordChars) and
       (after >= cmd.len or cmd[after] notin WordChars):
      return true
    i = at + 1

proc mentionsCd*(cmd: string): bool =
  mentionsWord(cmd, "cd")

proc insertPrompt*(t: var Terminal) =
  ## The branch is cached: without that, `.git/HEAD` would be read again after
  ## every single command. The cache is kept honest by the file itself -- a
  ## `git checkout` rewrites `HEAD`, and so does a switch made in another
  ## window entirely, neither of which this terminal is told about. Per prompt
  ## that costs one look at the file's date and size; finding `HEAD` in the
  ## first place is the walk up the tree, and reading it is only worth doing
  ## when the stamp says it changed.
  ##
  ## The stamp is taken before the read, so a `HEAD` rewritten between the two
  ## is caught by the next prompt rather than remembered as up to date.
  ##
  ## The cache also remembers *which* directory it read, because `cwd` is a
  ## public field: a host that sets it directly never goes through
  ## `runCommand`, and would otherwise get the previous checkout's branch next
  ## to the new path. `runCommand` drops the cache outright for the one case a
  ## stamp cannot catch: a command that moves this terminal into a different
  ## checkout, or makes a repository where there was none.
  if t.branchDir != t.cwd:
    t.branchDir = t.cwd
    t.headFile = headFileOf(t.cwd)
    t.headStamp = stampOf(t.headFile)
    t.branch = branchOf(t.headFile)
  else:
    let stamp = stampOf(t.headFile)
    if stamp != t.headStamp:
      t.headStamp = stamp
      t.branch = branchOf(t.headFile)
  if t.branch.len > 0:
    t.ed.appendOutput(t.cwd & " [" & t.branch & "]>")
  else:
    t.ed.appendOutput(t.cwd & ">")
  # A prompt is not a program's output, and redrawing a live tail must never
  # reach back over one. Saying it here rather than at each of the places that
  # write a prompt is what keeps the two from drifting apart.
  t.liveStart = t.ed.len

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
  t.caretToEnd()
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
    requests.send(ThreadTask(cwd: t.cwd, cmd: cmd, cols: t.cols, rows: t.rows))
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
  # that needs the answer. A `git` is here for what watching `HEAD` cannot
  # catch -- `git init` and `git clone .` make a repository where the prompt
  # had no `HEAD` to watch. A `git checkout` in one that already exists needs
  # no help, and neither does a checkout made behind this terminal's back.
  if mentionsCd(cmd) or mentionsWord(cmd, "git"): t.branchDir.setLen 0
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
      t.endOutput()
      requests.send(ThreadTask(cwd: t.cwd, cmd: cmd,
                               cols: t.cols, rows: t.rows))
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

proc renderRows(t: var Terminal; rows: openArray[TermRow];
                trailingNewline: bool) =
  ## The rows into the buffer, in as few insertions as it takes.
  ##
  ## One per row is what this obviously wants to be, and it is what makes a
  ## megabyte of output quadratic: `appendOutput` works out which line the
  ## caret ended up on, and that is a walk of the buffer, so a `git log -p`
  ## of forty thousand rows walks it forty thousand times. Rows that agree
  ## about whether the program colored them go in together, and since a
  ## program either colors its output or does not, that is usually all of them.
  var i = 0
  while i < rows.len:
    var j = i
    while j + 1 < rows.len and rows[j+1].colored == rows[i].colored: inc j
    var text = ""
    for k in i .. j:
      text.add rows[k].text
      if trailingNewline or k < rows.high: text.add "\L"
    let start = t.ed.len
    t.ed.appendOutput(text, highlight = not rows[i].colored)
    if rows[i].colored:
      var pos = start
      for k in i .. j:
        for run in rows[k].runs:
          if run.tc != TokenClass.None:
            t.ed.setStyleRange(pos, pos + run.len - 1, run.tc)
          pos += run.len
        if trailingNewline or k < rows.high: inc pos    # past the line break
      t.ed.markProgramColored(pos)
    i = j + 1

proc showOutput(t: var Terminal; raw: string) =
  ## What a program printed, as rows.
  ##
  ## A row it can still draw on again is not written into the buffer once and
  ## left there: a progress meter rewrites its line every time it moves, so
  ## the whole live tail comes back off and goes on again. Rows the program
  ## has printed past are final and are never touched a second time -- which
  ## is what keeps the cost of this to the handful of rows a meter uses,
  ## whatever the length of the output above them.
  ##
  ## A row the program colored keeps the program's colors. A row it did not is
  ## still the highlighter's to guess at, which is what keeps a `+` line green
  ## in the output of something that never heard of color.
  let final = t.screen.feed(raw, t.ed.tabSize)
  t.ed.truncateOutput(t.liveStart)
  t.renderRows(final, trailingNewline = true)
  t.liveStart = t.ed.len
  t.renderRows(t.screen.rows, trailingNewline = false)

proc update*(t: var Terminal): bool =
  ## Takes whatever the thread running a program has said since the last look.
  ## True when it said anything -- output to show, or the end of the program
  ## that was printing it.
  ##
  ## The result is for a host that draws when its window has changed rather
  ## than once per timer tick: a program prints on a thread of its own, so
  ## nothing else about a frame reveals that the terminal is no longer showing
  ## what it showed. Such a host also has to call this itself, and not leave
  ## it to `draw`: a frame that is never drawn is a frame that never asked.
  result = false
  if t.processRunning:
    if responses.peek > 0:
      # Everything that has piled up since the last look, not one piece of it.
      # A program printing a megabyte hands it over in four-kilobyte pieces,
      # and one piece per frame is hundreds of frames before the last of it is
      # on screen -- the output would still be scrolling past long after the
      # program had finished. Bounded, so that no single frame can be spent on
      # an unbounded amount of it.
      const MaxPerFrame = 256 * 1024
      var text = ""
      var over = false
      while responses.peek > 0 and text.len < MaxPerFrame and not over:
        let piece = responses.recv()
        text.add piece.text
        if piece.finished: over = true
      let resp = ThreadReply(text: text, finished: over)
      if resp.text.len > 0:
        t.showOutput(resp.text)
      if resp.finished:
        t.processRunning = false
        t.process.setLen 0
        # A program that died in the middle of a color, or halfway through
        # drawing a row, must not leave the next one carrying on from there.
        t.endOutput()
        t.ed.appendOutput "\L"
        t.insertPrompt()
      result = true

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
    screen: initTermScreen(),
    cols: 80, rows: 24,
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
  # What a program starting here will be told it has to draw on. Read every
  # frame because the panel is resized by dragging, and nothing else says so.
  let ch = t.ed.charSize
  t.cols = max(20, area.w div ch.w)
  t.rows = max(4, area.h div ch.h)
  discard t.update()

  if focused:
    # The keys the terminal answers itself. Everything it does not name here
    # -- the arrows with a modifier on them, Home and End, the clipboard, the
    # mouse -- reaches SynEdit untouched, and works on what a program printed
    # exactly as it works in the editor.
    if e.kind == TextInputEvent:
      # Typing is for the command line, wherever the caret was left standing.
      t.caretToEnd()
    elif e.kind == KeyDownEvent:
      let ctrl = CtrlPressed in e.mods
      let shift = ShiftPressed in e.mods
      case e.key
      of KeyUp:
        # The history, but only from the line it belongs to: with the caret up
        # in the output, Up is what it is in the editor and walks it further
        # up. Shift and Ctrl always mean select and scroll.
        if not ctrl and not shift and t.ed.cursor.int > t.ed.readOnly:
          let sug = t.hist[t.process].suggest(up = true)
          if sug.len > 0:
            t.emptyCmd()
            t.ed.insertText(sug)
          t.ed.render(area, showCursor = true)
          return
      of KeyDown:
        if not ctrl and not shift and t.ed.cursor.int > t.ed.readOnly:
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
        t.caretToEnd()
        result = t.enterPressed()
        t.ed.render(area, showCursor = true)
        return
      of KeyC:
        # A selection is what Ctrl+C is for everywhere else, so it is a copy
        # here too and SynEdit gets the key. Only with nothing selected does
        # it mean the other thing and stop the program.
        if ctrl and t.processRunning and not t.ed.hasSelection:
          t.sendBreak()
          t.ed.render(area, showCursor = true)
          return
      of KeyV:
        # Pasted text is typed text: it goes where typing goes.
        if ctrl: t.caretToEnd()
      else: discard

  let edAct = t.ed.draw(e, area, focused)
  case edAct.kind
  of ctrlHover:
    result = TermAction(kind: ctrlHover, pos: edAct.pos)
  of ctrlClick:
    result = TermAction(kind: ctrlClick, pos: edAct.pos)
  of noAction, closeLine: discard
