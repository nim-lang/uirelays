## ANSI escape sequences -- what a program asks for, as a token class.
##
## A terminal panel is not a terminal: it has no grid, no addressable cursor
## and no program that believes it is talking to one. What it does have is
## output from tools that colour it, and those tools ask for colour and
## nothing else. Measured on the two that get read most here::
##
##   git log -p (color.ui=always)  ^[[m ^[[1m ^[[31m ^[[32m ^[[33m ^[[36m
##   nim c --colors:on             ^[[0m ^[[1m ^[[31m ^[[36m
##   ls --color=always             ^[[0m ^[[01;34m
##
## Not one cursor movement between them. So this reads SGR -- `ESC [ ... m`,
## the colour -- and *swallows* everything else, which is the other half of
## the job: an escape nobody understands must disappear rather than come out
## as `^[[?25h` in the middle of a line.
##
## What comes out is clean text plus the runs of it that carry a colour, ready
## for `SynEdit.appendOutput` to insert and `setStyleRange` to paint.

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

proc parseAnsi*(st: var AnsiState; input: string; tabSize: int;
                text: var string; runs: var seq[AnsiRun]): bool =
  ## Append the printable part of `input` to `text` and the colors of it to
  ## `runs`. True when `input` carried any SGR at all -- which is what tells
  ## the caller whether the colors here are the program's, or whether the
  ## highlighter should go on guessing them from the shape of the lines.
  ##
  ## `text` comes out normalised the way `rawInsert` would normalise it --
  ## tabs expanded, carriage returns dropped -- so that a run counts the same
  ## bytes the buffer ends up holding and the two cannot drift apart.
  result = false
  let s = if st.partial.len == 0: input else: st.partial & input
  st.partial.setLen 0
  var cur = st.tokenClass
  var runLen = 0

  template flush() =
    if runLen > 0:
      runs.add AnsiRun(len: runLen, tc: cur)
      runLen = 0

  template emit(c: char) =
    text.add c
    inc runLen

  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\e':
      let e = escapeEnd(s, i)
      if e < 0:
        # Cut in half. Keep it for the next chunk -- unless it has grown past
        # anything a real sequence could be, in which case it was never one.
        if s.len - i <= MaxPartial: st.partial = s[i .. ^1]
        break
      if s[i+1] == '[' and s[e-1] == 'm':
        result = true
        var params: seq[int] = @[]
        var n = -1
        for k in i+2 ..< e-1:
          case s[k]
          of '0'..'9': n = (if n < 0: 0 else: n) * 10 + (ord(s[k]) - ord('0'))
          of ';':
            params.add (if n < 0: 0 else: n)
            n = -1
          else:
            # A private sequence: `ESC[>4m` sets something about keys, not
            # about color, and must not be read as one.
            params.setLen 0
            n = -1
            break
        if n >= 0: params.add n
        let before = st.tokenClass
        st.applySgr(params)
        if st.tokenClass != before:
          flush()
          cur = st.tokenClass
      i = e
    else:
      # The same filtering `rawInsert` does, done here so that a run's length
      # is the number of bytes the buffer will hold.
      case c
      of '\C': discard
      of '\t':
        for j in 1..tabSize: emit ' '
      of '\0': emit '_'
      else: emit c
      inc i
  flush()
