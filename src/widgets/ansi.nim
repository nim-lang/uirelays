## ANSI escape sequences -- what a program asks for, as a token class.
##
## The panel runs its programs on a pty (see `pty`), so they believe they are
## talking to a terminal and say everything they would say to one. Most of
## that is colour. Measured on what actually gets read here::
##
##   git log -p         ^[[m ^[[1m ^[[31m ^[[32m ^[[33m ^[[36m ^[[1;36m
##   nim c --colors:on  ^[[0m ^[[1m ^[[31m ^[[36m
##   a progress meter   \r ^[[K, and ^[[A when it counts several things
##
## So this reads two things and *swallows* the rest, which is as much of the
## job as either: an escape nobody has an answer for must disappear rather
## than come out as `^[[?25h` in the middle of a line.
##
## The first is SGR -- `ESC [ ... m` -- as a token class, which is how the
## rest of this program already says what colour something is.
##
## The second is where the cursor went, and only as far as a meter takes it.
## What that needs is not a screen but the last few rows of one, still open to
## being drawn on again; that is `TermScreen`, at the bottom of this file.

import theme

type
  AnsiRun* = object
    ## `len` bytes of the emitted text are `tc`. Runs are consecutive and
    ## cover all of it, so a walk over them needs no positions of its own.
    len*: int
    tc*: TokenClass

  AnsiState* = object
    ## What survives between two chunks of output. A program's colour stays
    ## in force until it says otherwise, and a `read` can cut an escape in
    ## half, so neither can be worked out from a chunk alone.
    color: int          ## the ANSI color in force, 0..15; -1 is the default
    bold: bool          ## `ESC[1m`, which makes a color its bright twin
    partial: string     ## an escape sequence cut by the end of a chunk

const
  MaxPartial = 256
    ## How much of an unfinished escape sequence is worth keeping. A real one
    ## is a dozen bytes; anything longer is a lone `ESC` in binary output, and
    ## holding on to the rest of the file waiting for it to end is how a
    ## terminal that met a `.tar` stops showing anything at all.

  Xterm: array[16, tuple[r, g, b: int]] = [
    ## What the sixteen colors *are*, as xterm draws them. Only for measuring
    ## against: a program that asks for `38;2;215;119;87` picked that value
    ## with a terminal in mind, so the nearest of these says which of the
    ## sixteen it meant, and the theme then says what that one looks like here.
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]

  AnsiClass*: array[16, TokenClass] = [
    ## The sixteen, as token classes. `Red`, `Green` and `Yellow` are the ones
    ## the console highlighter already guesses with -- a `-` line, a `+` line,
    ## a `warning:` -- and a theme that has chosen a shade for those has chosen
    ## it for these too. One knob, not two that must be kept looking alike.
    TokenClass.Black, TokenClass.Red, TokenClass.Green, TokenClass.Yellow,
    TokenClass.Blue, TokenClass.Magenta, TokenClass.Cyan, TokenClass.White,
    TokenClass.BrightBlack, TokenClass.BrightRed, TokenClass.BrightGreen,
    TokenClass.BrightYellow, TokenClass.BrightBlue, TokenClass.BrightMagenta,
    TokenClass.BrightCyan, TokenClass.BrightWhite]

proc initAnsiState*(): AnsiState =
  AnsiState(color: -1, bold: false, partial: "")

proc tokenClass(st: AnsiState): TokenClass =
  ## The class the state currently paints in. Bold makes a color its bright
  ## twin, which is what a terminal has done with `ESC[1m` since the hardware
  ## had one intensity and eight wires: `ls` says `01;34` and means bright
  ## blue. Bold on its own is the same thing said about the default color, and
  ## it is worth honouring: `git log` sets it and nothing else on the
  ## `commit`/`diff --git` headers, and dropping it would leave the one line
  ## the output is organised around looking like all the others.
  if st.color < 0: (if st.bold: TokenClass.BrightWhite else: TokenClass.None)
  elif st.bold and st.color < 8: AnsiClass[st.color + 8]
  else: AnsiClass[st.color]

proc nearest(r, g, b: int): int =
  ## Which of the sixteen a color is closest to, by plain distance in RGB.
  ## Good enough for the job: the question is only ever which *name* a program
  ## had in mind, and the answers are far apart.
  result = 0
  var best = high(int)
  for i in 0 ..< 16:
    let dr = r - Xterm[i].r
    let dg = g - Xterm[i].g
    let db = b - Xterm[i].b
    let d = dr*dr + dg*dg + db*db
    if d < best:
      best = d
      result = i

proc cubeColor(idx: int): int =
  ## A 256-color index as one of the sixteen. 0..15 are the sixteen already;
  ## 16..231 are a 6x6x6 cube; 232..255 a ramp of greys.
  if idx < 16: idx
  elif idx < 232:
    let n = idx - 16
    template level(v: int): int = (if v == 0: 0 else: 55 + 40 * v)
    nearest(level(n div 36), level((n div 6) mod 6), level(n mod 6))
  else:
    let v = 8 + 10 * (idx - 232)
    nearest(v, v, v)

proc applySgr(st: var AnsiState; params: seq[int]) =
  ## `ESC [ ... m`. Everything that is not a foreground color is read past:
  ## backgrounds have nowhere to go in a theme whose cells carry one class
  ## each, and italics and underlines are not worth a class apiece.
  if params.len == 0:
    st.color = -1
    st.bold = false
    return
  var i = 0
  while i < params.len:
    let p = params[i]
    case p
    of 0: st.color = -1; st.bold = false
    of 1: st.bold = true
    of 22: st.bold = false
    of 30..37: st.color = p - 30
    of 39: st.color = -1
    of 90..97: st.color = p - 90 + 8
    of 38:
      # `38;5;n` is one of 256, `38;2;r;g;b` a color in full. Both are read to
      # the end whether or not they are used, or the numbers behind them would
      # come out as separate attributes.
      if i + 1 < params.len and params[i+1] == 5:
        if i + 2 < params.len: st.color = cubeColor(params[i+2])
        i += 2
      elif i + 1 < params.len and params[i+1] == 2:
        if i + 4 < params.len:
          st.color = nearest(params[i+2], params[i+3], params[i+4])
        i += 4
    of 48:
      # A background, which is swallowed -- but its arguments have to be
      # stepped over all the same.
      if i + 1 < params.len and params[i+1] == 5: i += 2
      elif i + 1 < params.len and params[i+1] == 2: i += 4
    else: discard
    inc i

proc escapeEnd(s: string; start: int): int =
  ## One past the end of the escape sequence at `start`, or -1 when the string
  ## runs out first and the rest of it has to wait for the next chunk.
  ##
  ## Only enough of the shape of each kind to know where it stops: what is in
  ## the middle matters for `ESC [ ... m` alone, and the caller reads that off
  ## the same bytes.
  var i = start + 1
  if i >= s.len: return -1
  case s[i]
  of '[':
    # CSI: parameter bytes, then intermediates, then one final byte.
    inc i
    while i < s.len and s[i] in {'\x30'..'\x3F'}: inc i
    while i < s.len and s[i] in {'\x20'..'\x2F'}: inc i
    if i >= s.len: return -1
    return i + 1
  of ']', 'P', 'X', '^', '_':
    # A string sequence -- OSC and friends -- ending at BEL or at ST (`ESC \`).
    inc i
    while i < s.len:
      if s[i] == '\a': return i + 1
      if s[i] == '\e':
        if i + 1 >= s.len: return -1
        if s[i+1] == '\\': return i + 2
      inc i
    return -1
  else:
    # Two bytes: `ESC 7`, `ESC M`, `ESC =`.
    return i + 1

# ---------------------------------------------------------------------------
# The screen a progress bar draws on
# ---------------------------------------------------------------------------

## Everything above turns bytes into color. What follows turns the *movements*
## into rows, and only as far as a progress bar needs:
##
##   \r      back to the first column, and print the line again
##   \b      one column back
##   ESC[K   rub out the rest of the line
##   ESC[nA  up n rows, for a meter that draws on several
##   ESC[nG  to column n
##
## That is what `curl`, `git clone`, `cargo`, `pip` and `docker` do, and it is
## all they do. What it is *not* is a terminal: there is no addressable screen
## here, only the last few rows of output, still open to being rewritten. A
## row that falls off the end of that tail is final, and goes into the buffer
## as text like any other. A program that tries to draw further up than the
## tail reaches -- a full-screen one, which is the other kind -- finds the top
## of it and draws there instead, which will look wrong. That is the trade:
## the tools that get read in a panel are the ones that print and stop.

const LiveRows* = 16
  ## How many rows stay open to rewriting. A meter uses one, or one per thing
  ## it is counting; sixteen is past anything that is still a meter, and the
  ## cost of the tail is that it is redrawn whenever it changes.

type
  TermCell* = object
    ## One column. `n` of 0 is a column never written to, which reads as a
    ## space -- a program may jump past the end of a row and print there.
    b: array[4, char]
    n: uint8
    tc*: TokenClass

  TermRow* = object
    cells*: seq[TermCell]
    colored*: bool     ## whether the program asked for any color in this row.
                       ## A row that did not is still the highlighter's, which
                       ## is what keeps a plain `git diff` green and red.

  TermScreen* = object
    ## The live tail, and the parser state that feeds it.
    rows*: seq[TermRow]
    cy*, cx*: int
    st: AnsiState

proc initTermScreen*(): TermScreen =
  TermScreen(rows: @[TermRow()], cy: 0, cx: 0, st: initAnsiState())

proc text*(r: TermRow): string =
  ## The row as bytes, with the columns nobody wrote to as spaces and the run
  ## of them at the end left off -- a meter that shortens its line should not
  ## leave the buffer holding the width of the longest it ever was.
  var last = -1
  for i, c in r.cells:
    if c.n > 0'u8: last = i
  for i in 0 .. last:
    let c = r.cells[i]
    if c.n == 0'u8: result.add ' '
    else:
      for k in 0 ..< c.n.int: result.add c.b[k]

proc runs*(r: TermRow): seq[AnsiRun] =
  ## The row's colors, as runs over the bytes `text` produced.
  var last = -1
  for i, c in r.cells:
    if c.n > 0'u8: last = i
  var cur = TokenClass.None
  var n = 0
  for i in 0 .. last:
    let c = r.cells[i]
    let tc = if c.n == 0'u8: TokenClass.None else: c.tc
    let w = if c.n == 0'u8: 1 else: c.n.int
    if tc != cur and n > 0:
      result.add AnsiRun(len: n, tc: cur)
      n = 0
    cur = tc
    n += w
  if n > 0: result.add AnsiRun(len: n, tc: cur)

proc put(sc: var TermScreen; bytes: string; tc: TokenClass) =
  ## One grapheme into the column the cursor is on, and the cursor moves past
  ## it. A row grows to reach a column that was jumped to.
  if bytes.len == 0 or bytes.len > 4: return
  while sc.rows.len <= sc.cy: sc.rows.add TermRow()
  if sc.cx < 0: sc.cx = 0
  while sc.rows[sc.cy].cells.len <= sc.cx: sc.rows[sc.cy].cells.add TermCell()
  var cell = TermCell(n: uint8(bytes.len), tc: tc)
  for i, ch in bytes: cell.b[i] = ch
  sc.rows[sc.cy].cells[sc.cx] = cell
  if tc != TokenClass.None: sc.rows[sc.cy].colored = true
  inc sc.cx

proc feed*(sc: var TermScreen; input: string; tabSize: int): seq[TermRow] =
  ## Take a chunk of what a program printed. What comes back is the rows that
  ## have been pushed out of the live tail by it and can no longer be drawn
  ## on -- they are final, in the order they were printed.
  result = @[]
  let s = if sc.st.partial.len == 0: input else: sc.st.partial & input
  sc.st.partial.setLen 0
  var i = 0

  template row(): untyped = sc.rows[sc.cy]

  template ensureRow() =
    while sc.rows.len <= sc.cy: sc.rows.add TermRow()

  while i < s.len:
    let c = s[i]
    case c
    of '\e':
      let e = escapeEnd(s, i)
      if e < 0:
        # Cut in half by the end of the chunk. Keep it for the next one --
        # unless it has grown past anything a real sequence could be, in which
        # case it was never one and waiting for its end would swallow the file.
        if s.len - i <= MaxPartial: sc.st.partial = s[i .. ^1]
        break
      if s[i+1] == '[':
        # Read the parameters once; which of them matter depends on the final
        # byte, and everything whose final byte is not named here is swallowed.
        var params: seq[int] = @[]
        var n = -1
        var private = false
        for k in i+2 ..< e-1:
          case s[k]
          of '0'..'9': n = (if n < 0: 0 else: n) * 10 + (ord(s[k]) - ord('0'))
          of ';':
            params.add (if n < 0: 0 else: n)
            n = -1
          else:
            # `ESC[?25l`, `ESC[>4m`: a private sequence, about something other
            # than what is on the screen.
            private = true
            break
        if n >= 0: params.add n
        let p0 = if params.len > 0: params[0] else: 0
        let count = max(p0, 1)
        if not private:
          case s[e-1]
          of 'm': sc.st.applySgr(params)
          of 'A': sc.cy = max(0, sc.cy - count)
          of 'B': sc.cy += count; ensureRow()
          of 'C': sc.cx += count
          of 'D': sc.cx = max(0, sc.cx - count)
          of 'G': sc.cx = max(0, count - 1)
          of 'd': sc.cy = max(0, count - 1); ensureRow()
          of 'K':
            ensureRow()
            case p0
            of 1:
              for k in 0 .. min(sc.cx, row.cells.high): row.cells[k] = TermCell()
            of 2: row.cells.setLen 0
            else:
              if sc.cx < row.cells.len: row.cells.setLen sc.cx
          else: discard
      i = e
    of '\c':
      sc.cx = 0
      inc i
    of '\L':
      # A terminal's line feed goes *down* and stays in its column; the
      # carriage return that puts it back at the left is a separate character,
      # and on a pty the driver supplies it. This is not a terminal, and the
      # panel it writes into means "next line" by a newline -- so this does
      # both. The `\r\n` a pty actually delivers then simply says it twice.
      inc sc.cy
      sc.cx = 0
      ensureRow()
      inc i
    of '\b':
      sc.cx = max(0, sc.cx - 1)
      inc i
    of '\t':
      for j in 1..tabSize: sc.put(" ", sc.st.tokenClass)
      inc i
    of '\0':
      sc.put("_", sc.st.tokenClass)
      inc i
    else:
      # One grapheme, however many bytes it took to write it. A rune that the
      # end of the chunk cut in half waits for the rest, the same as an escape
      # sequence does -- half of one in the buffer would draw as a box.
      var w = 1
      if ord(c) >= 0xF0: w = 4
      elif ord(c) >= 0xE0: w = 3
      elif ord(c) >= 0xC0: w = 2
      if i + w > s.len:
        if s.len - i <= MaxPartial: sc.st.partial = s[i .. ^1]
        break
      sc.put(s[i ..< i+w], sc.st.tokenClass)
      i += w

  # Whatever the cursor can no longer reach is final.
  if sc.rows.len > LiveRows:
    let done = sc.rows.len - LiveRows
    result = sc.rows[0 ..< done]
    sc.rows = sc.rows[done .. ^1]
    sc.cy = max(0, sc.cy - done)
