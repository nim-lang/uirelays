## A pseudo-terminal, so that a program believes a person is reading it.
##
## Everything a command-line tool decides about how to talk -- whether to
## color, whether `git log` decorates, whether a progress meter is worth
## drawing -- it decides by asking whether its output is a terminal. Answering
## that with a pipe and then arguing with the answer through environment
## variables works one tool at a time and one setting at a time. A pty answers
## yes once, and every tool believes it.
##
## What comes back is a terminal's worth of escape sequences, of which this
## panel understands color and the handful of movements a progress bar makes.
## The rest is swallowed (see `ansi`), so a full-screen program will look
## wrong here -- that is the trade, and it is the right way round: the tools
## that get read here are the ones that print and stop.
##
## POSIX only. On Windows the terminal keeps its pipes, since the equivalent
## there is ConPTY and a different piece of work.

when defined(posix):
  import std/[posix, strtabs]

  const ptyHeader =
    when defined(macosx) or defined(openbsd) or defined(netbsd): "<util.h>"
    elif defined(freebsd) or defined(dragonfly): "<libutil.h>"
    else: "<pty.h>"

  when not (defined(macosx) or defined(android)):
    {.passL: "-lutil".}

  type
    Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>",
              final, pure.} = object
      ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

  proc forkpty(amaster: ptr cint; name: cstring; termp: pointer;
               winp: ptr Winsize): Pid {.importc, header: ptyHeader.}

  proc exitNow(code: cint) {.importc: "_exit", header: "<unistd.h>",
                             noreturn.}
    ## `quit` would run this process's exit handlers -- in a forked child that
    ## means flushing its parent's buffers and tearing down state the parent
    ## still owns. `_exit` leaves all of it alone.

  var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: uint

  type
    Pty* = object
      master*: cint    ## our end; -1 when nothing is running
      pid*: Pid        ## the child, which `forkpty` made a session leader, so
                       ## its process *group* is this same number -- which is
                       ## what a signal meant for "the program in front" goes to
      alive*: bool
      exitCode*: int   ## meaningful once `alive` has gone false

  proc setSize*(p: Pty; cols, rows: int) =
    ## Tell the program how wide it may draw. Without this it believes the
    ## 80x24 of a terminal nobody has owned since 1978, and wraps its output
    ## somewhere other than where the panel does.
    if p.master < 0: return
    var ws = Winsize(ws_row: cushort(max(rows, 1)), ws_col: cushort(max(cols, 1)))
    discard ioctl(p.master, TIOCSWINSZ, addr ws)

  proc envToSeq(env: StringTableRef): seq[string] =
    result = @[]
    if env != nil:
      for k, v in env: result.add k & "=" & v

  proc startPty*(bin: string; args: seq[string]; workDir: string;
                 env: StringTableRef; cols, rows: int): Pty =
    ## Run `bin` on a terminal of its own. Everything the child will need is
    ## built before the fork: between the fork and the exec it may not
    ## allocate, because the allocator it inherited belongs to a thread that
    ## did not come with it.
    result = Pty(master: -1, pid: 0, alive: false)
    var ws = Winsize(ws_row: cushort(max(rows, 1)),
                     ws_col: cushort(max(cols, 1)))
    var argv = allocCStringArray(@[bin] & args)
    var envp = allocCStringArray(envToSeq(env))
    var master: cint = -1
    let pid = forkpty(addr master, nil, nil, addr ws)
    if pid < 0:
      deallocCStringArray(argv)
      deallocCStringArray(envp)
      return
    if pid == 0:
      # The child. `forkpty` has already given it the slave side as its
      # controlling terminal and as all three standard descriptors.
      if workDir.len > 0: discard chdir(workDir.cstring)
      discard execvpe(argv[0], argv, envp)
      exitNow(127)
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    result.master = master
    result.pid = pid
    result.alive = true

  proc waitForOutput*(p: Pty; timeoutMs: int): bool =
    ## True as soon as there is something to read, or the far end has gone.
    ## The timeout is what lets the loop notice a request that arrives while
    ## the program is quiet -- typed input, or Ctrl+C.
    if p.master < 0: return false
    var fds = default(TFdSet)
    FD_ZERO(fds)
    FD_SET(p.master, fds)
    var tv = Timeval(tv_sec: posix.Time(timeoutMs div 1000),
                     tv_usec: Suseconds((timeoutMs mod 1000) * 1000))
    result = select(p.master + 1, addr fds, nil, nil, addr tv) == 1

  proc readAvailable*(p: Pty; buf: var string): int =
    ## What has arrived, which may be part of a line. When the child closes the
    ## other end a pty reports `EIO` rather than an end of file, so anything
    ## that is not a positive count means the same thing here: nothing more.
    if p.master < 0: return 0
    result = posix.read(p.master, addr buf[0], buf.len)
    if result < 0: result = 0

  proc writeInput*(p: Pty; s: string) =
    ## Typed text, on its way to the program. The terminal driver on the other
    ## side is what turns it into a line for a program waiting on one.
    if p.master < 0 or s.len == 0: return
    var off = 0
    while off < s.len:
      let n = posix.write(p.master, addr s[off], s.len - off)
      if n <= 0: break
      off += n

  proc interrupt*(p: Pty) =
    ## What Ctrl+C means: a signal to the program in front, not to the one
    ## process this panel happens to have started. `forkpty` made the child a
    ## session leader, so its process group is its own pid, and the negative
    ## of that reaches the whole pipeline it may have built.
    if p.alive: discard kill(Pid(-p.pid), SIGINT)

  proc terminate*(p: var Pty) =
    ## Harder than `interrupt`, for a program that would not take the hint.
    if not p.alive: return
    discard kill(Pid(-p.pid), SIGHUP)
    discard kill(Pid(-p.pid), SIGKILL)

  proc running*(p: var Pty): bool =
    ## Whether the child is still there, without waiting for it. Reaping it
    ## here is what keeps it from becoming a zombie.
    if not p.alive: return false
    var status: cint = 0
    let r = waitpid(p.pid, status, WNOHANG)
    if r == p.pid:
      p.alive = false
      p.exitCode = if WIFEXITED(status): WEXITSTATUS(status)
                   else: 128 + WTERMSIG(status)
    result = p.alive

  proc close*(p: var Pty): int {.discardable.} =
    ## Waits for the child if it has not been waited for yet, and answers how
    ## it went, the way a shell would report it.
    if p.alive:
      var status: cint = 0
      discard waitpid(p.pid, status, 0)
      p.alive = false
      p.exitCode = if WIFEXITED(status): WEXITSTATUS(status)
                   else: 128 + WTERMSIG(status)
    if p.master >= 0:
      discard posix.close(p.master)
      p.master = -1
    result = p.exitCode
