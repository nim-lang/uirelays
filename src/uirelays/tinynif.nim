## tinynif.nim -- a lexer for NIF, small enough to depend on nothing.
##
## NIF is a parenthesized format: a tree is `(tag child*)` and everything else
## is an atom. That is all this module knows about it; it turns an input string
## into a stream of tokens and leaves every question of *meaning* to its users.
## In particular the tags stay `string`s here: mapping them to an enum is the
## job of whoever parses the tags, because only they know their own vocabulary.
##
## Parsing is done by keeping the current token in a variable and advancing it,
## which is enough lookahead for a recursive descent parser:
##
##   var lex = initLexer(src)
##   var tok = next(lex)
##   while tok.kind != tkParRi:
##     ...
##     tok = next(lex)
##
## Nothing here raises: a malformed input yields a `tkError` token whose `text`
## is the reason and whose `line`/`col` say where, so the message can go
## straight into a status bar. A caller that keeps calling `next` past an error
## keeps getting errors, so it is safe to check for one at the end.
##
## Deliberate omissions -- add them the day something needs them:
## * No floating point literals. A `1.5` is reported as an error rather than
##   silently truncated.
## * Unsigned and typed literal suffixes are not distinguished from plain
##   integers; a trailing `u` is accepted and the digits are what you get.
## * NIF's own line information (the `<line>,<col>` prefixes that generated
##   files carry) is not understood. This lexer counts lines itself, which is
##   what a hand-written file needs.
##
## One addition, for the same reason: `#` starts a comment that runs to the end
## of the line. Plain NIF has no comments, but a file a human edits does need
## them.

type
  TokenKind* = enum
    tkEof,        ## the end of the input
    tkError,      ## malformed input; `text` is the reason
    tkParLe,      ## `(` -- `text` is the tag directly behind it
    tkParRi,      ## `)`
    tkDot,        ## `.` on its own: the empty node, NIF's way of saying
                  ## "this slot is not filled in"
    tkIdent,      ## a name: `cell`
    tkSymbol,     ## a name with a dot in it: `foo.3.mymod`
    tkSymbolDef,  ## the same, but introduced by a `:`, which is how NIF marks
                  ## the place a symbol is defined
    tkIntLit,     ## `intVal` has the value
    tkCharLit,    ## `intVal` has the byte
    tkStringLit   ## `text` has the value, escapes already resolved

  Token* = object
    kind*: TokenKind
    text*: string    ## the tag, name, string value or error message
    intVal*: int64   ## the value of an integer or character literal
    line*, col*: int ## where the token starts, both 1-based

  Lexer* = object
    input: string
    pos: int
    line, col: int

const
  # A '\0' ends the input, so having it in here saves every loop a second test.
  Delimiters = {'\0', ' ', '\t', '\r', '\n', '(', ')', '"', '\''}

proc initLexer*(input: string; line = 1; col = 1): Lexer =
  ## `line` and `col` are where the input starts, for the benefit of a caller
  ## that lexes a fragment out of a larger file.
  result = Lexer(input: input, pos: 0, line: line, col: col)

proc at(lex: Lexer; offset = 0): char =
  ## The character `offset` ahead, or '\0' at the end of the input.
  let i = lex.pos + offset
  result = if i < lex.input.len: lex.input[i] else: '\0'

proc bump(lex: var Lexer) =
  if lex.at == '\n':
    inc lex.line
    lex.col = 1
  else:
    inc lex.col
  inc lex.pos

proc setError(tok: var Token; msg: string) =
  tok.kind = tkError
  tok.text = msg

proc hexValue(c: char): int =
  case c
  of '0'..'9': result = ord(c) - ord('0')
  of 'a'..'f': result = ord(c) - ord('a') + 10
  of 'A'..'F': result = ord(c) - ord('A') + 10
  else: result = -1

proc skipBlanks(lex: var Lexer) =
  while true:
    let c = lex.at
    if c == ' ' or c == '\t' or c == '\r' or c == '\n':
      lex.bump
    elif c == '#':
      while lex.at != '\n' and lex.at != '\0': lex.bump
    else:
      break

proc readEscape(lex: var Lexer; dest: var string): bool =
  ## A backslash and exactly two hex digits -- NIF has no other escape, so a
  ## newline in a string is `\0A` and a backslash is `\5C`.
  lex.bump
  let hi = hexValue(lex.at)
  let lo = hexValue(lex.at(1))
  if hi < 0 or lo < 0:
    result = false
  else:
    dest.add chr(hi * 16 + lo)
    lex.bump
    lex.bump
    result = true

proc readString(lex: var Lexer; tok: var Token) =
  lex.bump # the opening quote
  tok.kind = tkStringLit
  while true:
    let c = lex.at
    if c == '"':
      lex.bump
      break
    elif c == '\0' or c == '\n':
      tok.setError "unterminated string literal"
      break
    elif c == '\\':
      if not lex.readEscape(tok.text):
        tok.setError "expected two hex digits after '\\' in a string literal"
        break
    else:
      tok.text.add c
      lex.bump

proc readChar(lex: var Lexer; tok: var Token) =
  lex.bump # the opening apostrophe
  var buf = ""
  if lex.at == '\\':
    if not lex.readEscape(buf):
      tok.setError "expected two hex digits after '\\' in a character literal"
      return
  elif lex.at == '\0' or lex.at == '\n' or lex.at == '\'':
    tok.setError "empty character literal"
    return
  else:
    buf.add lex.at
    lex.bump
  if lex.at != '\'':
    tok.setError "expected a closing apostrophe"
    return
  lex.bump
  tok.kind = tkCharLit
  tok.intVal = int64(ord(buf[0]))

proc readNumber(lex: var Lexer; tok: var Token) =
  let negative = lex.at == '-'
  if lex.at == '-' or lex.at == '+': lex.bump
  var value = 0'i64
  var digits = 0
  var base = 10'i64
  if lex.at == '0' and (lex.at(1) == 'x' or lex.at(1) == 'X'):
    lex.bump
    lex.bump
    base = 16
  while true:
    let d = hexValue(lex.at)
    if d < 0 or int64(d) >= base: break
    if value > (high(int64) - int64(d)) div base:
      tok.setError "integer literal is too large"
      return
    value = value * base + int64(d)
    inc digits
    lex.bump
  if digits == 0:
    tok.setError "expected digits in an integer literal"
    return
  # Whatever sticks to the digits is either a float or a typo; both deserve to
  # be named rather than quietly dropped on the floor.
  if lex.at == 'u': lex.bump
  if (lex.at == '.' and hexValue(lex.at(1)) >= 0) or lex.at == 'e' or lex.at == 'E':
    tok.setError "floating point literals are not supported"
    return
  if lex.at notin Delimiters:
    tok.setError "unexpected '" & $lex.at & "' in an integer literal"
    return
  tok.kind = tkIntLit
  tok.intVal = if negative: -value else: value

proc readName(lex: var Lexer; tok: var Token) =
  let isDef = lex.at == ':'
  if isDef: lex.bump
  var hasDot = false
  while lex.at notin Delimiters:
    if lex.at == '.': hasDot = true
    tok.text.add lex.at
    lex.bump
  if tok.text.len == 0:
    tok.setError "expected a name after ':'"
  elif isDef: tok.kind = tkSymbolDef
  elif tok.text == ".": tok.kind = tkDot
  elif hasDot: tok.kind = tkSymbol
  else: tok.kind = tkIdent

proc next*(lex: var Lexer): Token =
  ## The next token. At the end of the input this keeps returning `tkEof`.
  lex.skipBlanks
  result = Token(kind: tkEof, text: "", intVal: 0, line: lex.line, col: lex.col)
  let c = lex.at
  case c
  of '\0':
    discard
  of '(':
    lex.bump
    result.kind = tkParLe
    # The tag sits directly behind the '(' -- `(add 3 4)`, never `( add 3 4)`.
    while lex.at notin Delimiters:
      result.text.add lex.at
      lex.bump
    if result.text.len == 0:
      result.setError "expected a tag directly after '('"
  of ')':
    lex.bump
    result.kind = tkParRi
  of '"':
    lex.readString(result)
  of '\'':
    lex.readChar(result)
  of '0'..'9':
    lex.readNumber(result)
  of '-', '+':
    # A sign only starts a number if a digit follows; `-` alone is a name.
    if lex.at(1) in {'0'..'9'}: lex.readNumber(result)
    else: lex.readName(result)
  else:
    lex.readName(result)

proc position*(tok: Token): string =
  ## "line:col", for the front of an error message.
  result = $tok.line & ":" & $tok.col

proc `$`*(tok: Token): string =
  ## The token as it would be written, for "expected ..., got ..." messages.
  case tok.kind
  of tkEof: result = "end of input"
  of tkError: result = tok.text
  of tkParLe: result = "(" & tok.text
  of tkParRi: result = ")"
  of tkDot: result = "."
  of tkIdent, tkSymbol, tkSymbolDef: result = tok.text
  of tkIntLit: result = $tok.intVal
  of tkStringLit: result = "\"" & tok.text & "\""
  of tkCharLit:
    const HexDigits = "0123456789ABCDEF"
    let b = int(tok.intVal) and 0xff
    let c = chr(b)
    if c >= ' ' and c <= '~': result = "'" & $c & "'"
    else: result = "'\\" & HexDigits[b shr 4] & HexDigits[b and 0xf] & "'"
