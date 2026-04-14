## SynEdit -- syntax-aware text editor widget for uirelays.
##
## Ported from nimedit's editor component. Self-contained: no external
## dependencies beyond uirelays itself.
##
## Immediate-mode widget: a single ``draw`` call handles both input and
## rendering. The area is passed every frame so the caller owns layout.
##
## Usage::
##
##   var ed: SynEdit
##   ed.init(font)             # uses catppuccin mocha theme by default
##   ed.setText("hello world")
##   # in your main loop:
##   ed.draw(e, rect(10, 10, 600, 400))
##
## Read-only label::
##
##   var label: SynEdit
##   label.init(font)
##   label.showLineNumbers = false
##   label.setText("Status: OK")
##   label.readOnly = label.len - 1
##
## Terminal / console::
##
##   var term: SynEdit
##   term.init(font)
##   term.lang = langConsole
##   term.appendOutput("$ ")   # user types after the prompt

import ../uirelays/[coords, screen, input]
from strutils import Whitespace

# ---------------------------------------------------------------------------
# Token classes & source languages
# ---------------------------------------------------------------------------

type
  TokenClass* {.pure.} = enum
    None, Whitespace, DecNumber, BinNumber, HexNumber,
    OctNumber, FloatNumber, Identifier, Keyword, StringLit,
    LongStringLit, CharLit, Backticks,
    EscapeSequence,
    Operator, Punctuation, Comment, LongComment, RegularExpression,
    TagStart, TagStandalone, TagEnd, Key, Value, RawData, Assembler,
    Preprocessor, Directive, Command, Rule, Link, Label,
    Reference, Text, Other, Green, Yellow, Red

  SourceLanguage* = enum
    langNone, langNim, langCpp, langCsharp, langC, langJava, langJs,
    langXml, langHtml, langConsole

const
  Letters* = {'a'..'z', 'A'..'Z', '0'..'9', '_', '\128'..'\255'}
  TabWidth = 2

  additionalIndentChars: array[SourceLanguage, set[char]] = [
    langNone: {},
    langNim: {'(', '[', '{', ':', '='},
    langCpp: {'(', '[', '{'},
    langCsharp: {'(', '[', '{'},
    langC: {'(', '[', '{'},
    langJava: {'(', '[', '{'},
    langJs: {'(', '[', '{'},
    langXml: {'>'},
    langHtml: {'>'},
    langConsole: {}]

proc fileExtToLanguage*(ext: string): SourceLanguage =
  case ext
  of ".nim", ".nims": langNim
  of ".cpp", ".hpp", ".cxx", ".h": langCpp
  of ".c": langC
  of ".js": langJs
  of ".java": langJava
  of ".cs": langCsharp
  of ".xml": langXml
  of ".html", ".htm": langHtml
  else: langNone

# ---------------------------------------------------------------------------
# Gap buffer types
# ---------------------------------------------------------------------------

type
  Cell* = object
    c*: char
    s*: TokenClass

  ActionKind = enum
    ins, insFinished, dele, delFinished

  Action = object
    k: ActionKind
    pos, version: int
    word: string

  Indexer = object
    version: int
    currentlyIndexing: int
    position: int

  Theme* = object
    fg*: array[TokenClass, Color]   ## per-token foreground colors
    bg*: Color                      ## editor background
    selBg*: Color                   ## selection background
    bracketBg*: Color               ## bracket match background
    cursorColor*: Color             ## cursor bar color
    lineNumColor*: Color            ## line number foreground

  SynEdit* = object
    # Gap buffer
    front*, back*: seq[Cell]
    cursor*: Natural
    # Line tracking
    firstLine*, currentLine*, numberOfLines*: Natural
    firstLineOffset*: Natural
    span*: int
    desiredCol*: Natural
    # Selection
    selected*: tuple[a, b: int]
    # Undo
    actions: seq[Action]
    undoIdx: int
    version*: int
    cacheId: int
    # Rendering
    font*: Font
    theme*: Theme
    showLineNumbers*: bool
    focused*: bool                  ## receives keyboard input; set by the app
    cursorVisible*: bool
    lastBlinkTick*: int
    cursorDim: tuple[x, y, h: int]
    # Text
    tabSize*: int
    lang*: SourceLanguage
    changed*: bool
    readOnly*: int                  ## -1 = fully editable;
                                    ## >= 0 = positions <= readOnly are protected
    # Bracket matching
    bracketA, bracketB: int
    # Mouse
    mouseX, mouseY, clicks: int
    # Highlighting
    highlighter: Indexer
    # Cache
    offsetToLineCache: array[20, tuple[version, offset, line: int]]

# ---------------------------------------------------------------------------
# Gap buffer access
# ---------------------------------------------------------------------------

proc getCell*(s: SynEdit; i: Natural): Cell {.inline.} =
  if i < s.front.len:
    s.front[i]
  else:
    let j = i - s.front.len
    if j <= s.back.high:
      s.back[s.back.high - j]
    else:
      Cell(c: '\L')

proc setCellStyle*(s: var SynEdit; i: Natural; tc: TokenClass) =
  if i < s.front.len:
    s.front[i].s = tc
  else:
    let j = i - s.front.len
    if j <= s.back.high:
      s.back[s.back.high - j].s = tc

proc `[]`*(s: SynEdit; i: Natural): char {.inline.} = s.getCell(i).c

proc len*(s: SynEdit): int {.inline.} = s.front.len + s.back.len

# ---------------------------------------------------------------------------
# UTF-8 helpers
# ---------------------------------------------------------------------------

template ones(n: untyped): untyped = ((1 shl n) - 1)

proc graphemeLen*(s: SynEdit; i: Natural): Positive =
  result = 1
  if i >= s.len: return
  let ch = s[i]
  if ord(ch) <=% 127: return
  elif ord(ch) shr 5 == 0b110: result = 2
  elif ord(ch) shr 4 == 0b1110: result = 3
  elif ord(ch) shr 3 == 0b11110: result = 4
  elif ord(ch) shr 2 == 0b111110: result = 5
  elif ord(ch) shr 1 == 0b1111110: result = 6

proc lastRuneLen(s: SynEdit; last: int): int =
  if last < 0: return 1
  if ord(s[last]) <= 127: return 1
  var L = 0
  while last - L >= 0 and ord(s[last - L]) shr 6 == 0b10: inc L
  result = L + 1

# ---------------------------------------------------------------------------
# Syntax highlighting
# ---------------------------------------------------------------------------

type
  GeneralTokenizer = object
    kind: TokenClass
    start, length: int
    buf: ptr SynEdit
    pos: int
    state: TokenClass

const
  nimKeywords = ["addr", "and", "as", "asm", "atomic", "bind", "block",
    "break", "case", "cast", "concept", "const", "continue", "converter",
    "defer", "discard", "distinct", "div", "do",
    "elif", "else", "end", "enum", "except", "export",
    "finally", "for", "from", "func",
    "generic", "if", "import", "in", "include",
    "interface", "is", "isnot", "iterator", "let", "macro", "method",
    "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc",
    "ptr", "raise", "ref", "return", "shl", "shr", "static",
    "template", "try", "tuple", "type", "using", "var", "when", "while", "with",
    "without", "xor", "yield"]

  OpChars = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.',
             '|', '=', '%', '&', '$', '@', '~', ':', '\x80'..'\xFF'}

proc nimGetKeyword(id: string): TokenClass =
  for k in nimKeywords:
    if id == k: return TokenClass.Keyword
  TokenClass.Identifier

proc nimMultilineComment(g: var GeneralTokenizer; pos: int;
                         isDoc: bool): int =
  var pos = pos
  var nesting = 0
  while pos < g.buf[].len:
    case g.buf[][pos]
    of '#':
      if isDoc:
        if g.buf[][pos+1] == '#' and g.buf[][pos+2] == '[': inc nesting
      elif g.buf[][pos+1] == '[': inc nesting
      inc pos
    of ']':
      if isDoc:
        if g.buf[][pos+1] == '#' and g.buf[][pos+2] == '#':
          if nesting == 0: inc(pos, 3); break
          dec nesting
      elif g.buf[][pos+1] == '#':
        if nesting == 0: inc(pos, 2); break
        dec nesting
      inc pos
    else: inc pos
  result = pos

proc nimNumberPostfix(g: var GeneralTokenizer; position: int): int =
  var pos = position
  if g.buf[][pos] == '\'': inc(pos)
  case g.buf[][pos]
  of 'd', 'D': g.kind = TokenClass.FloatNumber; inc(pos)
  of 'f', 'F':
    g.kind = TokenClass.FloatNumber; inc(pos)
    if g.buf[][pos] in {'0'..'9'}: inc(pos)
    if g.buf[][pos] in {'0'..'9'}: inc(pos)
  of 'i', 'I', 'u', 'U':
    inc(pos)
    if g.buf[][pos] in {'0'..'9'}: inc(pos)
    if g.buf[][pos] in {'0'..'9'}: inc(pos)
  else: discard
  result = pos

proc nimNumber(g: var GeneralTokenizer; position: int): int =
  const decChars = {'0'..'9', '_'}
  var pos = position
  g.kind = TokenClass.DecNumber
  while g.buf[][pos] in decChars: inc(pos)
  if g.buf[][pos] == '.':
    if g.buf[][pos+1] == '.': return pos
    g.kind = TokenClass.FloatNumber; inc(pos)
    while g.buf[][pos] in decChars: inc(pos)
  if g.buf[][pos] in {'e', 'E'}:
    g.kind = TokenClass.FloatNumber; inc(pos)
    if g.buf[][pos] in {'+', '-'}: inc(pos)
    while g.buf[][pos] in decChars: inc(pos)
  result = nimNumberPostfix(g, pos)

proc nimNextToken(g: var GeneralTokenizer) =
  const
    hexChars = {'0'..'9', 'A'..'F', 'a'..'f', '_'}
    octChars = {'0'..'7', '_'}
    binChars = {'0'..'1', '_'}
    SymChars = {'a'..'z', 'A'..'Z', '0'..'9', '\x80'..'\xFF'}
  var pos = g.pos
  g.start = g.pos
  if g.state == TokenClass.StringLit:
    g.kind = TokenClass.StringLit
    while pos < g.buf[].len:
      case g.buf[][pos]
      of '\\':
        g.kind = TokenClass.EscapeSequence; inc(pos)
        case g.buf[][pos]
        of 'x', 'X': inc(pos); (if g.buf[][pos] in hexChars: inc(pos)); (if g.buf[][pos] in hexChars: inc(pos))
        of '0'..'9': (while g.buf[][pos] in {'0'..'9'}: inc(pos))
        else: inc(pos)
        break
      of '\L', '\C': g.state = TokenClass.None; break
      of '\"': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  elif g.state == TokenClass.LongStringLit:
    g.kind = TokenClass.LongStringLit
    while pos < g.buf[].len:
      if g.buf[][pos] == '\"':
        inc(pos)
        if g.buf[][pos] == '\"' and g.buf[][pos+1] == '\"' and g.buf[][pos+2] != '\"':
          inc(pos, 2); break
      else: inc(pos)
    g.state = TokenClass.None
  elif g.state in {TokenClass.LongComment, TokenClass.Comment}:
    g.kind = g.state
    pos = nimMultilineComment(g, pos, g.kind == TokenClass.LongComment)
    g.state = TokenClass.None
  else:
    case g.buf[][pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf[].len and g.buf[][pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '#':
      if g.buf[][pos+1] == '#':
        g.kind = TokenClass.LongComment; inc pos
      else: g.kind = TokenClass.Comment
      if g.buf[][pos+1] == '[':
        g.state = g.kind
        pos = nimMultilineComment(g, pos+2, g.kind == TokenClass.LongComment)
        g.state = TokenClass.None
      else:
        while g.buf[][pos] != '\L': inc(pos)
    of 'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[][pos] in SymChars + {'_'}:
        add(id, g.buf[][pos]); inc(pos)
      if g.buf[][pos] == '\"':
        if g.buf[][pos+1] == '\"' and g.buf[][pos+2] == '\"':
          inc(pos, 3)
          g.kind = TokenClass.LongStringLit
          while pos < g.buf[].len:
            if g.buf[][pos] == '\"':
              inc(pos)
              if g.buf[][pos] == '\"' and g.buf[][pos+1] == '\"' and g.buf[][pos+2] != '\"':
                inc(pos, 2); break
            else: inc(pos)
        else:
          g.kind = TokenClass.RawData; inc(pos)
          while g.buf[][pos] != '\L':
            if g.buf[][pos] == '"' and g.buf[][pos+1] != '"': break
            inc(pos)
          if g.buf[][pos] == '\"': inc(pos)
      else:
        g.kind = nimGetKeyword(id)
    of '0':
      inc(pos)
      case g.buf[][pos]
      of 'b', 'B': inc(pos); (while g.buf[][pos] in binChars: inc(pos)); pos = nimNumberPostfix(g, pos)
      of 'x', 'X': inc(pos); (while g.buf[][pos] in hexChars: inc(pos)); pos = nimNumberPostfix(g, pos)
      of 'o', 'O': inc(pos); (while g.buf[][pos] in octChars: inc(pos)); pos = nimNumberPostfix(g, pos)
      else: pos = nimNumber(g, pos)
    of '1'..'9': pos = nimNumber(g, pos)
    of '\'':
      inc(pos); g.kind = TokenClass.CharLit
      while true:
        case g.buf[][pos]
        of '\L': break
        of '\'': inc(pos); break
        of '\\': inc(pos, 2)
        else: inc(pos)
    of '\"':
      inc(pos)
      if g.buf[][pos] == '\"' and g.buf[][pos+1] == '\"':
        inc(pos, 2)
        g.kind = TokenClass.LongStringLit
        while pos < g.buf[].len:
          if g.buf[][pos] == '\"':
            inc(pos)
            if g.buf[][pos] == '\"' and g.buf[][pos+1] == '\"' and g.buf[][pos+2] != '\"':
              inc(pos, 2); break
          else: inc(pos)
      else:
        g.kind = TokenClass.StringLit
        while true:
          case g.buf[][pos]
          of '\L': break
          of '\"': inc(pos); break
          of '\\': g.state = g.kind; break
          else: inc(pos)
    of '(', '[', '{':
      inc(pos); g.kind = TokenClass.Punctuation
      if g.buf[][pos] == '.' and g.buf[][pos+1] != '.': inc pos
    of ')', ']', '}', '`', ':', ',', ';':
      inc(pos); g.kind = TokenClass.Punctuation
    of '.':
      if g.buf[][pos+1] in {')', ']', '}'}:
        inc(pos, 2); g.kind = TokenClass.Punctuation
      else: g.kind = TokenClass.Operator; inc pos
    else:
      if g.buf[][pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[][pos] in OpChars: inc(pos)
      else:
        if pos < g.buf[].len: inc(pos)
        g.kind = TokenClass.None
  g.length = pos - g.pos
  g.pos = pos

proc clikeNextToken(g: var GeneralTokenizer; keywords: openArray[string]) =
  const
    hexChars = {'0'..'9', 'A'..'F', 'a'..'f'}
    octChars = {'0'..'7'}
    binChars = {'0'..'1'}
    symChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '\x80'..'\xFF'}
  var pos = g.pos
  g.start = g.pos
  if g.state == TokenClass.StringLit:
    g.kind = TokenClass.StringLit
    while true:
      case g.buf[][pos]
      of '\\':
        g.kind = TokenClass.EscapeSequence; inc(pos)
        case g.buf[][pos]
        of 'x', 'X': inc(pos); (if g.buf[][pos] in hexChars: inc(pos)); (if g.buf[][pos] in hexChars: inc(pos))
        of '0'..'9': (while g.buf[][pos] in {'0'..'9'}: inc(pos))
        else: inc(pos)
        break
      of '\L': g.state = TokenClass.None; break
      of '\"': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  elif g.state == TokenClass.LongComment:
    var nested = 0
    g.kind = TokenClass.LongComment
    while pos < g.buf[].len:
      case g.buf[][pos]
      of '*': inc(pos); (if g.buf[][pos] == '/': inc(pos); (if nested == 0: break))
      of '/': inc(pos); (if g.buf[][pos] == '*': inc(pos))
      else: inc(pos)
    g.state = TokenClass.None
  else:
    case g.buf[][pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf[].len and g.buf[][pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '/':
      inc(pos)
      if g.buf[][pos] == '/':
        g.kind = TokenClass.Comment
        while g.buf[][pos] != '\L': inc(pos)
      elif g.buf[][pos] == '*':
        g.kind = TokenClass.LongComment; inc(pos)
        while pos < g.buf[].len:
          case g.buf[][pos]
          of '*': inc(pos); (if g.buf[][pos] == '/': inc(pos); break)
          else: inc(pos)
      else: g.kind = TokenClass.Operator
    of '#':
      inc(pos); g.kind = TokenClass.Preprocessor
      while g.buf[][pos] in {' ', '\t'}: inc(pos)
      while g.buf[][pos] in symChars: inc(pos)
    of 'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[][pos] in symChars: add(id, g.buf[][pos]); inc(pos)
      g.kind = TokenClass.Identifier
      for kw in keywords:
        if kw == id: g.kind = TokenClass.Keyword; break
    of '0':
      inc(pos)
      case g.buf[][pos]
      of 'b', 'B': inc(pos); (while g.buf[][pos] in binChars: inc(pos))
      of 'x', 'X': inc(pos); (while g.buf[][pos] in hexChars: inc(pos))
      of '0'..'7': inc(pos); (while g.buf[][pos] in octChars: inc(pos))
      else:
        g.kind = TokenClass.DecNumber
        while g.buf[][pos] in {'0'..'9'}: inc(pos)
    of '1'..'9':
      g.kind = TokenClass.DecNumber
      while g.buf[][pos] in {'0'..'9'}: inc(pos)
    of '\'':
      g.kind = TokenClass.CharLit
      inc(pos)
      while g.buf[][pos] notin {'\L', '\''}: inc(pos)
      if g.buf[][pos] == '\'': inc(pos)
    of '\"':
      inc(pos); g.kind = TokenClass.StringLit
      while pos < g.buf[].len:
        case g.buf[][pos]
        of '\"': inc(pos); break
        of '\\': g.state = g.kind; break
        else: inc(pos)
    of '(', ')', '[', ']', '{', '}', ':', ',', ';', '.':
      inc(pos); g.kind = TokenClass.Punctuation
    else:
      if g.buf[][pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[][pos] in OpChars: inc(pos)
      else:
        if pos < g.buf[].len: inc(pos)
        g.kind = TokenClass.None
  g.length = pos - g.pos
  g.pos = pos

const
  cKeywords = ["_Bool", "_Complex", "_Imaginary", "auto",
    "break", "case", "char", "const", "continue", "default", "do", "double",
    "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int",
    "long", "register", "restrict", "return", "short", "signed", "sizeof",
    "static", "struct", "switch", "typedef", "union", "unsigned", "void",
    "volatile", "while"]
  cppKeywords = ["asm", "auto", "break", "case", "catch",
    "char", "class", "const", "continue", "default", "delete", "do", "double",
    "else", "enum", "extern", "float", "for", "friend", "goto", "if",
    "inline", "int", "long", "new", "operator", "private", "protected",
    "public", "register", "return", "short", "signed", "sizeof", "static",
    "struct", "switch", "template", "this", "throw", "try", "typedef",
    "union", "unsigned", "virtual", "void", "volatile", "while"]
  jsKeywords = ["abstract", "arguments", "boolean", "break", "byte",
    "case", "catch", "char", "class", "const", "continue", "debugger",
    "default", "delete", "do", "double", "else", "enum", "eval", "export",
    "extends", "false", "final", "finally", "float", "for", "function",
    "goto", "if", "implements", "import", "in", "instanceof", "int",
    "interface", "let", "long", "native", "new", "null",
    "package", "private", "protected", "public", "return",
    "short", "static", "super", "switch", "synchronized",
    "this", "throw", "throws", "transient", "true", "try", "typeof",
    "var", "void", "volatile", "while", "with", "yield"]

proc getNextToken(g: var GeneralTokenizer; lang: SourceLanguage) =
  case lang
  of langNone, langConsole:
    # no highlighting, consume one char
    g.start = g.pos
    if g.pos < g.buf[].len: inc g.pos
    g.kind = TokenClass.None
    g.length = g.pos - g.start
  of langNim: nimNextToken(g)
  of langCpp: clikeNextToken(g, cppKeywords)
  of langC: clikeNextToken(g, cKeywords)
  of langJs: clikeNextToken(g, jsKeywords)
  of langJava: clikeNextToken(g, jsKeywords)   # close enough
  of langCsharp: clikeNextToken(g, cppKeywords) # close enough
  of langXml, langHtml:
    # minimal: no highlighting
    g.start = g.pos
    if g.pos < g.buf[].len: inc g.pos
    g.kind = TokenClass.None
    g.length = g.pos - g.start

proc highlight(s: var SynEdit; first, last: int; initialState: TokenClass) =
  var g: GeneralTokenizer
  g.buf = addr s
  g.kind = low(TokenClass)
  g.start = first
  g.length = 0
  g.state = initialState
  g.pos = first
  while g.pos <= last:
    getNextToken(g, s.lang)
    if g.length == 0: break
    for i in 0 ..< g.length:
      s.setCellStyle(g.start + i, g.kind)

proc highlightLine(s: var SynEdit; oldCursor: Natural) =
  if s.lang == langNone: return
  var i = oldCursor.int
  while i >= 1 and s[i-1] != '\L': dec i
  let first = i
  i = s.cursor
  while s[i] != '\L': inc i
  let last = i
  let initialState = if first == 0: TokenClass.None else: s.getCell(first-1).s
  s.highlight(first, last, initialState)

proc highlightEverything(s: var SynEdit) =
  if s.lang != langNone:
    s.highlight(0, s.len - 1, TokenClass.None)

proc highlightIncrementally(s: var SynEdit) =
  if s.lang == langNone or s.highlighter.version == s.version: return
  const charsToIndex = 40 * 40
  if s.highlighter.currentlyIndexing != s.version:
    s.highlighter.currentlyIndexing = s.version
    s.highlighter.position = 0
  var i = s.highlighter.position
  if i < s.len:
    let initialState = if i == 0: TokenClass.None else: s.getCell(i-1).s
    var last = i + charsToIndex
    if last > s.len - 1:
      last = s.len - 1
    else:
      while s[last] != '\L': inc last
    s.highlight(i, last, initialState)
    s.highlighter.position = last + 1
  else:
    s.highlighter.version = s.version
    s.highlighter.currentlyIndexing = 0

# ---------------------------------------------------------------------------
# Line offset helpers
# ---------------------------------------------------------------------------

proc getLineFromOffset(s: SynEdit; pos: int): Natural =
  result = 0
  var p = pos
  var e = 0
  for ce in s.offsetToLineCache:
    if ce.version == s.cacheId:
      if ce.offset == pos: return ce.line
      if ce.offset < pos and ce.offset > e:
        e = ce.offset
        result = ce.line
  if p >= 0 and s[p] == '\L': dec p
  while p >= e:
    if s[p] == '\L': inc result
    dec p

proc getLineOffset(s: SynEdit; lines: Natural): int =
  var y = lines.int
  if y == 0: return 0
  for ce in s.offsetToLineCache:
    if ce.version == s.cacheId and ce.line == lines:
      return ce.offset
  while true:
    if s[result] == '\L':
      dec y
      if y == 0:
        inc result
        break
    inc result

proc updateLineCache(s: var SynEdit; offset: int; line: Natural) =
  var idx = 0
  for ce in mitems(s.offsetToLineCache):
    if ce.version != s.cacheId or idx == high(s.offsetToLineCache) or
       ce.offset >= offset:
      ce = (version: s.cacheId, offset: offset, line: line.int)
      break
    inc idx

proc setCurrentLine(s: var SynEdit) =
  s.currentLine = s.getLineFromOffset(s.cursor)
  s.currentLine = clamp(s.currentLine, 0, s.numberOfLines)

# ---------------------------------------------------------------------------
# Bracket matching
# ---------------------------------------------------------------------------

proc cursorMoved(s: var SynEdit) =
  const brackets = {'(', '{', '[', ']', '}', ')'}
  s.bracketA = -1
  s.bracketB = -1
  if s[s.cursor] notin brackets: return
  case s[s.cursor]
  of '(':
    var i = s.cursor.int + 1; var counter = 0
    while i < s.len:
      if s[i] == ')':
        if counter <= 0: s.bracketA = i; s.bracketB = i; break
        dec counter
      elif s[i] == '(': inc counter
      inc i
  of '[':
    var i = s.cursor.int + 1; var counter = 0
    while i < s.len:
      if s[i] == ']':
        if counter <= 0: s.bracketA = i; s.bracketB = i; break
        dec counter
      elif s[i] == '[': inc counter
      inc i
  of '{':
    var i = s.cursor.int + 1; var counter = 0
    while i < s.len:
      if s[i] == '}':
        if counter <= 0: s.bracketA = i; s.bracketB = i; break
        dec counter
      elif s[i] == '{': inc counter
      inc i
  of ')':
    var i = s.cursor.int - 1; var counter = 0
    while i >= 0:
      if s[i] == '(':
        if counter <= 0: s.bracketA = i; s.bracketB = i; break
        dec counter
      elif s[i] == ')': inc counter
      dec i
  of ']':
    var i = s.cursor.int - 1; var counter = 0
    while i >= 0:
      if s[i] == '[':
        if counter <= 0: s.bracketA = i; s.bracketB = i; break
        dec counter
      elif s[i] == ']': inc counter
      dec i
  of '}':
    var i = s.cursor.int - 1; var counter = 0
    while i >= 0:
      if s[i] == '{':
        if counter <= 0: s.bracketA = i; s.bracketB = i; break
        dec counter
      elif s[i] == '}': inc counter
      dec i
  else: discard

# ---------------------------------------------------------------------------
# Scroll
# ---------------------------------------------------------------------------

proc upFirstLineOffset(s: var SynEdit) =
  if s.firstLineOffset == 0: return
  var i = s.firstLineOffset.int - 1
  while i > 0 and s[i-1] != '\L': dec i
  s.firstLineOffset = max(0, i)

proc downFirstLineOffset(s: var SynEdit) =
  var i = s.firstLineOffset.int
  while s[i] != '\L': inc i
  s.firstLineOffset = i + 1

proc scrollLines*(s: var SynEdit; amount: int) =
  let oldFirstLine = s.firstLine
  s.firstLine = clamp(s.firstLine.int + amount, 0, max(0, s.numberOfLines.int - 1)).Natural
  var a = s.firstLine.int - oldFirstLine.int
  if a < 0:
    while a < 0: s.upFirstLineOffset(); inc a
  elif a > 0:
    while a > 0: s.downFirstLineOffset(); dec a

proc scroll(s: var SynEdit; amount: int) =
  s.currentLine = (s.currentLine.int + amount).clamp(0, s.numberOfLines.int).Natural
  if s.currentLine < s.firstLine:
    s.scrollLines(s.currentLine.int - s.firstLine.int)
  elif s.currentLine > s.firstLine + s.span.Natural - 2:
    s.scrollLines(s.currentLine.int - (s.firstLine.int + s.span - 2))

# ---------------------------------------------------------------------------
# Gap buffer editing primitives
# ---------------------------------------------------------------------------

proc prepareForEdit(s: var SynEdit) =
  if s.cursor < s.front.len:
    for i in countdown(s.front.len - 1, s.cursor):
      s.back.add(s.front[i])
    s.front.setLen(s.cursor)
  elif s.cursor > s.front.len:
    let chars = max(s.cursor - s.front.len, 0)
    var took = 0
    for i in countdown(s.back.len - 1, max(s.back.len - chars, 0)):
      s.front.add(s.back[i])
      inc took
    s.back.setLen(s.back.len - took)
    s.cursor = s.front.len
  s.changed = true

template edit(s: var SynEdit) =
  s.undoIdx = s.actions.len - 1

proc rawInsert(s: var SynEdit; c: char) =
  inc s.cacheId
  case c
  of '\L':
    s.front.add Cell(c: '\L')
    inc s.numberOfLines
    s.scroll(1)
    inc s.cursor
  of '\C': discard
  of '\t':
    for i in 1..s.tabSize:
      s.front.add Cell(c: ' ')
      inc s.cursor
  of '\0':
    s.front.add Cell(c: '_')
    inc s.cursor
  else:
    s.front.add Cell(c: c)
    inc s.cursor

proc rawInsert(s: var SynEdit; text: string) =
  for c in text: s.rawInsert(c)

proc getColumn(s: SynEdit): int =
  var i = s.cursor.int
  while i > 0 and s[i-1] != '\L': dec i
  while i < s.cursor.int and s[i] != '\L':
    i += s.graphemeLen(i)
    inc result

proc rawBackspace(s: var SynEdit; overrideUtf8: bool; undoAction: var string) =
  inc s.cacheId
  if s.cursor <= 0: return
  var x: int
  let ch = s.front[s.cursor - 1].c
  if ch.ord < 128 or overrideUtf8:
    x = 1
    if ch == '\L':
      dec s.numberOfLines
      s.scroll(-1)
  else:
    x = s.lastRuneLen(s.cursor - 1)
  if undoAction.len != 0 or true:
    for i in countdown(s.front.len - 1, s.front.len - x):
      undoAction.add s.front[i].c
  s.cursor -= x
  s.front.setLen(s.cursor)

proc filterForInsert(text: string): string =
  result = newStringOfCap(text.len)
  for c in text:
    case c
    of '\C': discard
    of '\t': (for j in 1..TabWidth: result.add ' ')
    else: result.add c

# ---------------------------------------------------------------------------
# Undo / Redo
# ---------------------------------------------------------------------------

proc backspaceNoSelect(s: var SynEdit; overrideUtf8 = false) =
  if s.cursor <= 0: return
  if s.cursor.int - 1 <= s.readOnly: return
  let oldCursor = s.cursor
  s.prepareForEdit()
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  var ah = s.actions.high
  if ah == -1 or s.actions[ah].k != dele or s.actions[ah].pos != oldCursor.int:
    s.actions.setLen(ah + 2)
    inc ah
    s.actions[ah].word = ""
    s.actions[ah].k = dele
    s.actions[ah].version = s.version
  s.rawBackspace(overrideUtf8, s.actions[ah].word)
  s.actions[ah].pos = s.cursor
  s.edit()
  if s.actions[ah].word.len == 1 and s.actions[ah].word[0] in Whitespace:
    s.actions[ah].k = delFinished
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)

proc insertNoSelect(s: var SynEdit; text: string; singleUndoOp = false) =
  if s.cursor.int <= s.readOnly or text.len == 0: return
  let oldCursor = s.cursor
  s.prepareForEdit()
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  if s.actions.len > 0 and s.actions[^1].k == ins and
     s.actions[^1].pos == oldCursor.int - s.actions[^1].word.len and not singleUndoOp:
    s.actions[^1].word.add text.filterForInsert
  else:
    s.actions.add(Action(k: ins, pos: s.cursor, word: text.filterForInsert,
                         version: s.version))
  if text[^1] in Whitespace or singleUndoOp: s.actions[^1].k = insFinished
  s.edit()
  s.rawInsert(text)
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)

proc gotoPos(s: var SynEdit; pos: int) =
  let pos = clamp(pos, 0, s.len)
  s.cursor = pos.Natural
  s.currentLine = s.getLineFromOffset(pos)
  if s.currentLine >= s.firstLine + 1 and s.currentLine < s.firstLine + s.span.Natural - 1:
    discard "still in view"
  else:
    s.firstLine = max(0, s.currentLine.int - (s.span div 2)).Natural
    s.firstLineOffset = s.getLineOffset(s.firstLine)

proc applyUndo(s: var SynEdit; a: Action) =
  let oldCursor = s.cursor
  if a.k <= insFinished:
    s.gotoPos(a.pos + a.word.len)
    s.prepareForEdit()
    var dummy: string = ""
    for i in 1..a.word.len:
      s.rawBackspace(overrideUtf8 = true, dummy)
  else:
    s.gotoPos(a.pos)
    s.prepareForEdit()
    for i in countdown(a.word.len - 1, 0):
      s.rawInsert a.word[i]
  s.highlightLine(oldCursor)

proc applyRedo(s: var SynEdit; a: Action) =
  let oldCursor = s.cursor
  if a.k <= insFinished:
    s.gotoPos(a.pos)
    s.prepareForEdit()
    for i in countup(0, a.word.len - 1):
      s.rawInsert a.word[i]
  else:
    s.gotoPos(a.pos + a.word.len)
    s.prepareForEdit()
    var dummy: string = ""
    for i in 1..a.word.len:
      s.rawBackspace(overrideUtf8 = true, dummy)
  s.highlightLine(oldCursor)

template canUndo(s: SynEdit): bool =
  s.undoIdx >= 0 and s.undoIdx < s.actions.len

proc undo*(s: var SynEdit) =
  if s.canUndo:
    let v = s.actions[s.undoIdx].version
    s.applyUndo(s.actions[s.undoIdx])
    dec s.undoIdx
    while s.canUndo and s.actions[s.undoIdx].version == v:
      s.applyUndo(s.actions[s.undoIdx])
      dec s.undoIdx

proc redo*(s: var SynEdit) =
  inc s.undoIdx
  if s.canUndo:
    let v = s.actions[s.undoIdx].version
    s.applyRedo(s.actions[s.undoIdx])
    while s.undoIdx + 1 >= 0 and s.undoIdx + 1 < s.actions.len and
        s.actions[s.undoIdx + 1].version == v:
      inc s.undoIdx
      s.applyRedo(s.actions[s.undoIdx])
  else:
    dec s.undoIdx

# ---------------------------------------------------------------------------
# Cursor movement
# ---------------------------------------------------------------------------

proc rawLeft(s: var SynEdit) =
  if s.cursor > 0:
    if s[s.cursor - 1] == '\L':
      s.scroll(-1)
    s.cursor -= s.lastRuneLen(s.cursor - 1)
    s.desiredCol = s.getColumn().Natural

proc left*(s: var SynEdit; jump: bool) =
  s.rawLeft()
  if jump and s.cursor > 0:
    s.rawLeft()
    if s[s.cursor] in Letters:
      while s.cursor > 0 and s[s.cursor - 1] in Letters: s.rawLeft()
    else:
      while s.cursor > 0 and s[s.cursor - 1] notin Letters and
            s[s.cursor - 1] != '\L':
        s.rawLeft()
  s.cursorMoved()

proc rawRight(s: var SynEdit) =
  if s.cursor < s.len:
    if s[s.cursor] == '\L': s.scroll(1)
    s.cursor += s.graphemeLen(s.cursor)
    s.desiredCol = s.getColumn().Natural

proc right*(s: var SynEdit; jump: bool) =
  s.rawRight()
  if jump:
    if s[s.cursor] in Letters:
      while s.cursor < s.len and s[s.cursor] in Letters: s.rawRight()
    else:
      while s.cursor < s.len and s[s.cursor] notin Letters and
            s[s.cursor] != '\L':
        s.rawRight()
  s.cursorMoved()

proc up*(s: var SynEdit; jump: bool) =
  var col = s.desiredCol.int
  var i = s.cursor.int
  while i >= 1 and s[i-1] != '\L': dec i
  while i >= 1:
    dec i
    while i >= 1 and s[i-1] != '\L': dec i
    let notEmpty = s[i] > ' '
    if not jump or notEmpty:
      var c = col
      while i >= 0 and c > 0 and s[i] != '\L':
        i += s.graphemeLen(i)
        dec c
      s.scroll(-1)
      if not jump or notEmpty: break
  s.cursor = max(0, i).Natural
  s.cursorMoved()

proc down*(s: var SynEdit; jump: bool) =
  var col = s.desiredCol.int
  let L = s.len
  while s.cursor < L:
    if s[s.cursor] == '\L':
      s.scroll(1)
      if not jump or s[s.cursor.int + 1] > ' ': break
    s.cursor += 1
  s.cursor += 1
  var c = col
  while s.cursor < L and c > 0:
    if s[s.cursor] == '\L': break
    dec c
    s.cursor += 1
  if s.cursor > L: s.cursor = L.Natural
  s.cursorMoved()

proc home*(s: var SynEdit) =
  var i = s.cursor.int
  while i > 0 and s[i-1] != '\L': dec i
  # smart home: first go to first non-whitespace, then to column 0
  let lineStart = i
  while i < s.len and s[i] in {' ', '\t'}: inc i
  if i == s.cursor.int:
    s.cursor = lineStart.Natural
  else:
    s.cursor = i.Natural
  s.desiredCol = s.getColumn().Natural
  s.cursorMoved()

proc `end`*(s: var SynEdit) =
  while s.cursor < s.len and s[s.cursor] != '\L':
    s.cursor += 1
  s.desiredCol = s.getColumn().Natural
  s.cursorMoved()

proc pageUp*(s: var SynEdit) =
  let lines = max(1, s.span - 2)
  for i in 1..lines: s.up(false)

proc pageDown*(s: var SynEdit) =
  let lines = max(1, s.span - 2)
  for i in 1..lines: s.down(false)

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

proc selectAll*(s: var SynEdit) =
  s.selected = (0, s.len - 1)

proc deselect*(s: var SynEdit) {.inline.} =
  s.selected.b = -1

proc getSelectedText*(s: SynEdit): string =
  if s.selected.b < 0: return ""
  result = newStringOfCap(s.selected.b - s.selected.a + 1)
  for i in s.selected.a .. s.selected.b:
    result.add s[i]

proc removeSelectedText*(s: var SynEdit) =
  if s.selected.b < 0: return
  let a = s.selected.a
  let b = s.selected.b
  if a < 0 or b >= s.len: return
  s.cursor = (b + 1).Natural
  s.setCurrentLine()
  let oldCursor = s.cursor
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  s.actions.add(Action(k: delFinished, pos: s.cursor, word: "",
                       version: s.version))
  s.edit()
  while s.cursor.int > a and s.cursor > 0:
    if s.cursor.int - 1 <= s.readOnly: break
    s.prepareForEdit()
    s.rawBackspace(overrideUtf8 = true, s.actions[^1].word)
    s.actions[^1].pos = s.cursor
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)
  s.selected.b = -1

proc select(s: var SynEdit; oldPos, newPos: int; isLeft: bool) =
  if s.cursor.int >= s.selected.a and s.cursor.int <= s.selected.b:
    if isLeft:
      s.selected.b = newPos - s.lastRuneLen(newPos - 1)
    else:
      s.selected.a = newPos
  else:
    if s.selected.b < 0:
      if oldPos <= newPos:
        s.selected.a = oldPos
        s.selected.b = newPos - s.lastRuneLen(newPos - 1)
      else:
        s.selected.a = newPos
        s.selected.b = oldPos - s.lastRuneLen(oldPos - 1)
    else:
      if isLeft:
        s.selected.a = newPos
      else:
        s.selected.b = newPos - s.lastRuneLen(newPos - 1)
  if s.selected.b < s.selected.a: s.deselect()

proc selectLeft*(s: var SynEdit; jump: bool) =
  if s.cursor > 0:
    let old = s.cursor.int
    s.left(jump)
    s.select(old, s.cursor, true)

proc selectRight*(s: var SynEdit; jump: bool) =
  if s.cursor < s.len:
    let old = s.cursor.int
    s.right(jump)
    s.select(old, s.cursor, false)

proc selectUp*(s: var SynEdit; jump: bool) =
  if s.cursor > 0:
    let old = s.cursor.int
    s.up(jump)
    s.select(old, s.cursor, true)

proc selectDown*(s: var SynEdit; jump: bool) =
  if s.cursor < s.len:
    let old = s.cursor.int
    s.down(jump)
    s.select(old, s.cursor, false)

# ---------------------------------------------------------------------------
# High-level editing
# ---------------------------------------------------------------------------

proc insertChar*(s: var SynEdit; c: char) =
  inc s.version
  if s.selected.b >= 0 and c in {'(', '[', '{', '\'', '`', '"'}:
    var x: string
    case c
    of '(': x = "(" & s.getSelectedText() & ")"
    of '[': x = "[" & s.getSelectedText() & "]"
    of '{': x = "{" & s.getSelectedText() & "}"
    of '\'': x = "'" & s.getSelectedText() & "'"
    of '"': x = "\"" & s.getSelectedText() & "\""
    of '`': x = "`" & s.getSelectedText() & "`"
    else: discard
    s.removeSelectedText()
    s.insertNoSelect(x)
  else:
    s.removeSelectedText()
    s.insertNoSelect($c)
  s.cursorMoved()

proc insertText*(s: var SynEdit; text: string) =
  inc s.version
  s.removeSelectedText()
  s.insertNoSelect(text, singleUndoOp = true)
  s.cursorMoved()

proc backspace*(s: var SynEdit; smartIndent: bool) =
  inc s.version
  if s.selected.b < 0:
    if smartIndent:
      var spaces = 0
      var i = s.cursor.int - 1
      while i >= 0:
        case s[i]
        of ' ': inc spaces
        of '\L':
          if spaces == 0: spaces = 1
          break
        else: spaces = 1; break
        dec i
      for j in 1..min(s.tabSize, spaces):
        s.backspaceNoSelect()
    else:
      s.backspaceNoSelect()
  else:
    s.removeSelectedText()
  s.cursorMoved()

proc deleteKey*(s: var SynEdit) =
  if s.selected.b < 0:
    if s.cursor >= s.len: return
    let L = s.lastRuneLen(s.cursor.int + 1)
    s.cursor = (s.cursor.int + L).Natural
    s.setCurrentLine()
    s.backspace(false)
  else:
    s.removeSelectedText()
  s.cursorMoved()

proc insertEnter*(s: var SynEdit; smartIndent = true) =
  var i = s.cursor.int
  var inComment = false
  while i >= 1:
    case s[i-1]
    of '\L': break
    of '#': (if s.lang == langNim: inComment = true)
    else: discard
    dec i
  var toInsert = "\L"
  if smartIndent:
    while true:
      let c = s[i]
      if c == ' ' or c == '\t': toInsert.add c
      else: break
      inc i
    var last = s.cursor.int - 1
    while last > 0 and s[last] == ' ': dec last
    if last >= 0 and s[last] in additionalIndentChars[s.lang] and not inComment:
      for j in 1..s.tabSize: toInsert.add ' '
  inc s.version
  s.removeSelectedText()
  s.insertNoSelect(toInsert, singleUndoOp = true)
  s.cursorMoved()

proc indent*(s: var SynEdit) =
  inc s.version
  if s.selected.b < 0:
    for j in 1..s.tabSize:
      s.insertNoSelect(" ")
  else:
    var i = s.selected.a
    while i >= 1 and s[i-1] != '\L': dec i
    while i <= s.selected.b and i < s.len:
      s.cursor = i.Natural
      s.setCurrentLine()
      for j in 1..s.tabSize:
        s.insertNoSelect(" ")
        inc s.selected.b
      inc i
      while i < s.len and s[i] != '\L': inc i
      if s[i] == '\L': inc i

proc dedent*(s: var SynEdit) =
  inc s.version
  if s.selected.b < 0:
    var i = s.cursor.int
    while i >= 1 and s[i-1] != '\L': dec i
    if s[i] == ' ':
      var spaces = 1
      while spaces < s.tabSize and s[i + spaces] == ' ': inc spaces
      s.cursor = (i + spaces).Natural
      s.setCurrentLine()
      for j in 1..spaces:
        s.backspaceNoSelect()
  else:
    var i = s.selected.a
    while i >= 1 and s[i-1] != '\L': dec i
    while i <= s.selected.b and i < s.len:
      if s[i] == ' ':
        var spaces = 1
        while spaces < s.tabSize and s[i + spaces] == ' ': inc spaces
        s.cursor = (i + spaces).Natural
        s.setCurrentLine()
        for j in 1..spaces:
          s.backspaceNoSelect()
          if s.selected.b >= 0: dec s.selected.b
      while i < s.len and s[i] != '\L': inc i
      if i < s.len and s[i] == '\L': inc i
      else: break

proc gotoLine*(s: var SynEdit; line, col: int) =
  let line = clamp(line - 1, 0, max(0, s.numberOfLines.int - 1))
  s.cursor = s.getLineOffset(line).Natural
  s.currentLine = line.Natural
  let span = if s.span > 0: s.span else: 30
  s.firstLine = max(0, line - (span div 2)).Natural
  s.firstLineOffset = s.getLineOffset(s.firstLine)
  if col > 0:
    var c = 1
    while c <= col and s[s.cursor] != '\L':
      s.rawRight()
      inc c

# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------

proc fullText*(s: SynEdit): string =
  result = newStringOfCap(s.front.len + s.back.len)
  for i in 0 ..< s.front.len: result.add s.front[i].c
  for i in countdown(s.back.len - 1, 0): result.add s.back[i].c

proc clear*(s: var SynEdit) =
  inc s.cacheId
  s.front.setLen 0
  s.back.setLen 0
  s.actions.setLen 0
  s.currentLine = 0
  s.firstLine = 0
  s.numberOfLines = 0
  s.desiredCol = 0
  s.cursor = 0
  s.selected = (-1, -1)
  s.bracketA = -1
  s.bracketB = -1
  s.span = 0
  s.firstLineOffset = 0
  s.readOnly = -1
  s.clicks = 0
  s.undoIdx = 0
  s.cursorDim = (0, 0, 0)

proc setText*(s: var SynEdit; text: string) =
  s.clear()
  inc s.version
  for c in text:
    case c
    of '\L':
      s.front.add Cell(c: '\L')
      inc s.numberOfLines
    of '\C': discard
    of '\t':
      for j in 1..s.tabSize:
        s.front.add Cell(c: ' ')
    else:
      s.front.add Cell(c: c)
  s.cursor = 0
  s.highlightEverything()
  s.changed = false

proc loadFromFile*(s: var SynEdit; filename: string) =
  let text = readFile(filename)
  s.setText(text)

proc appendOutput*(s: var SynEdit; text: string) =
  ## Append text and mark everything as read-only up to the end.
  ## For terminal/console use: output is protected, user types after it.
  s.readOnly = -1
  s.gotoPos(s.len)
  s.prepareForEdit()
  s.rawInsert(text)
  s.highlightLine(s.cursor)
  s.readOnly = s.len - 1

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

proc catppuccinMocha*(): Theme =
  let fg = color(205, 214, 244)
  for tc in TokenClass:
    result.fg[tc] = fg
  result.fg[TokenClass.Keyword] = color(203, 166, 247)     # mauve
  result.fg[TokenClass.StringLit] = color(166, 227, 161)   # green
  result.fg[TokenClass.LongStringLit] = color(166, 227, 161)
  result.fg[TokenClass.CharLit] = color(166, 227, 161)
  result.fg[TokenClass.RawData] = color(166, 227, 161)
  result.fg[TokenClass.Comment] = color(108, 112, 134)     # overlay0
  result.fg[TokenClass.LongComment] = color(108, 112, 134)
  result.fg[TokenClass.DecNumber] = color(250, 179, 135)   # peach
  result.fg[TokenClass.BinNumber] = color(250, 179, 135)
  result.fg[TokenClass.HexNumber] = color(250, 179, 135)
  result.fg[TokenClass.OctNumber] = color(250, 179, 135)
  result.fg[TokenClass.FloatNumber] = color(250, 179, 135)
  result.fg[TokenClass.Operator] = color(137, 180, 250)    # blue
  result.fg[TokenClass.Punctuation] = color(147, 153, 178) # subtext0
  result.fg[TokenClass.EscapeSequence] = color(245, 194, 231) # pink
  result.fg[TokenClass.Preprocessor] = color(203, 166, 247)
  result.fg[TokenClass.Identifier] = fg
  result.fg[TokenClass.Green] = color(166, 227, 161)
  result.fg[TokenClass.Yellow] = color(249, 226, 175)
  result.fg[TokenClass.Red] = color(243, 139, 168)
  result.bg = color(30, 30, 46)
  result.selBg = color(88, 91, 112)
  result.bracketBg = color(69, 71, 90)
  result.cursorColor = color(205, 214, 244)
  result.lineNumColor = color(108, 112, 134)

proc init*(s: var SynEdit; font: Font; theme = catppuccinMocha()) =
  s.front = @[]
  s.back = @[]
  s.actions = @[]
  s.cursor = 0
  s.selected = (-1, -1)
  s.bracketA = -1
  s.bracketB = -1
  s.readOnly = -1
  s.tabSize = TabWidth
  s.lang = langNim
  s.font = font
  s.theme = theme
  s.showLineNumbers = false
  s.cursorVisible = true
  s.lastBlinkTick = 0

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

proc textWidth(font: Font; text: string): int =
  measureText(font, text).w

proc spaceForLines(s: SynEdit): int =
  if s.showLineNumbers:
    var n = s.numberOfLines + 1
    var digits = 1
    while n >= 10: n = n div 10; inc digits
    result = digits * textWidth(s.font, " ") + 8
  else:
    result = 0

proc getBg(s: SynEdit; i: int): Color =
  if i <= s.selected.b and s.selected.a <= i: return s.theme.selBg
  if i == s.bracketA or i == s.bracketB: return s.theme.bracketBg
  return s.theme.bg

const
  CharBufSize = 80

type
  DrawBuf = object
    s: ptr SynEdit
    tempStr: string
    dim: Rect
    cursorDim: Rect
    i, charsLen: int
    font: Font
    oldX, maxY, lineH, spaceWidth: int
    chars: array[CharBufSize, char]
    toCursor: array[CharBufSize, int]

proc drawSubtoken(db: var DrawBuf; ra, rb: int; fg, bg: Color) =
  db.tempStr.setLen 0
  for k in ra..rb: db.tempStr.add db.chars[k]
  let ext = measureText(db.font, db.tempStr)
  var d = db.dim
  d.w = ext.w
  d.h = ext.h
  # track cursor
  if db.cursorDim.h == 0 and
     db.toCursor[ra] <= db.s[].cursor.int and db.s[].cursor.int <= db.toCursor[rb + 1]:
    var idx = ra
    if db.toCursor[idx] == db.s[].cursor.int:
      db.cursorDim = d
    else:
      while idx <= rb and db.toCursor[idx] != db.s[].cursor.int: inc idx
      var other = ""
      for k in ra ..< idx: other.add db.chars[k]
      db.cursorDim = d
      db.cursorDim.x += textWidth(db.font, other)
  # mouse click handling
  if db.s[].clicks > 0:
    let p = point(db.s[].mouseX, db.s[].mouseY)
    if d.contains(p):
      db.s[].cursor = db.toCursor[ra].Natural
      db.s[].setCurrentLine()
      db.s[].clicks = 0
      db.s[].cursorMoved()
  discard drawText(db.font, d.x, d.y, db.tempStr, fg, bg)

proc drawToken(db: var DrawBuf; fg, bg: Color) =
  if db.dim.y + db.lineH > db.maxY: return
  db.tempStr.setLen 0
  for k in 0 ..< db.charsLen: db.tempStr.add db.chars[k]
  let ext = measureText(db.font, db.tempStr)
  let w = ext.w
  if db.dim.x + w + db.spaceWidth <= db.dim.w:
    drawSubtoken(db, 0, db.charsLen - 1, fg, bg)
    db.dim.x += w
  else:
    # wrapping: just draw what fits, then continue on next line
    var ra = 0
    while ra < db.charsLen:
      var probe = ra
      while probe < db.charsLen:
        db.tempStr.setLen 0
        for k in ra..probe: db.tempStr.add db.chars[k]
        let w2 = textWidth(db.font, db.tempStr)
        if db.dim.x + db.spaceWidth + w2 > db.dim.w:
          dec probe
          break
        inc probe
      if probe <= ra: break
      let rb = probe - 1
      db.tempStr.setLen 0
      for k in ra..rb: db.tempStr.add db.chars[k]
      let ext2 = textWidth(db.font, db.tempStr)
      drawSubtoken(db, ra, rb, fg, bg)
      db.dim.x += ext2
      ra = probe
      if ra < db.charsLen:
        db.dim.x = db.oldX
        db.dim.y += db.lineH
        if db.dim.y + db.lineH > db.maxY: break

proc drawTextLine(s: var SynEdit; i: int; dim: var Rect; blink: bool): int =
  var tokenClass = s.getCell(i).s
  var styleBg = s.getBg(i)

  var db: DrawBuf
  db.oldX = dim.x
  db.maxY = dim.h
  db.dim = dim
  db.font = s.font
  db.s = addr s
  db.i = i
  db.lineH = fontLineSkip(db.font)
  db.spaceWidth = textWidth(db.font, " ")
  db.tempStr = ""

  block outerLoop:
    while db.dim.y + db.lineH <= db.maxY:
      db.charsLen = 0
      while true:
        let cell = s.getCell(db.i)
        if cell.c == '\L':
          db.chars[db.charsLen] = '\0'
          db.toCursor[db.charsLen] = db.i
          if db.charsLen >= 1:
            db.drawToken(s.theme.fg[tokenClass], styleBg)
          elif db.i == s.cursor.int:
            db.cursorDim = db.dim
          # mouse click past end of line
          if s.clicks > 0 and s.mouseX > dim.x and
             db.dim.y + db.lineH > s.mouseY and s.mouseY >= db.dim.y:
            s.cursor = db.i.Natural
            s.setCurrentLine()
            s.clicks = 0
            s.cursorMoved()
          break outerLoop
        if cell.s != tokenClass or s.getBg(db.i) != styleBg:
          break
        elif db.charsLen == high(db.chars):
          break
        if cell.c == '\t':
          # expand tab
          db.chars[db.charsLen] = ' '
          db.toCursor[db.charsLen] = db.i
          inc db.charsLen
          var col = 1
          while col < s.tabSize and db.charsLen < high(db.chars):
            db.chars[db.charsLen] = ' '
            db.toCursor[db.charsLen] = db.i
            inc db.charsLen
            inc col
          db.chars[db.charsLen] = '\0'
        else:
          db.chars[db.charsLen] = cell.c
          db.toCursor[db.charsLen] = db.i
          inc db.charsLen
        inc db.i

      db.chars[db.charsLen] = '\0'
      db.toCursor[db.charsLen] = db.i
      if db.charsLen >= 1:
        db.drawToken(s.theme.fg[tokenClass], styleBg)
        tokenClass = s.getCell(db.i).s
        styleBg = s.getBg(db.i)

  dim = db.dim
  dim.y += fontLineSkip(s.font)
  dim.x = db.oldX
  if db.cursorDim.h > 0:
    if blink:
      fillRect(rect(db.cursorDim.x, db.cursorDim.y, 2, db.lineH), s.theme.cursorColor)
    s.cursorDim = (db.cursorDim.x, db.cursorDim.y, db.lineH)
  result = db.i + 1

# ---------------------------------------------------------------------------
# Mouse handling
# ---------------------------------------------------------------------------

proc mouseSelectCurrentToken(s: var SynEdit) =
  var first = s.cursor.int
  var last = s.cursor.int
  if s[s.cursor] in Letters:
    while first > 0 and s[first - 1] in Letters: dec first
    while last < s.len and s[last + 1] in Letters: inc last
  else:
    while first > 0 and s.getCell(first - 1).s == s.getCell(s.cursor).s and
          s[first - 1] != '\L':
      dec first
    while last < s.len and s.getCell(last + 1).s == s.getCell(s.cursor).s:
      inc last
  s.cursor = first.Natural
  s.selected = (first, last)
  s.cursorMoved()

proc mouseSelectWholeLine(s: var SynEdit) =
  var first = s.cursor.int
  while first > 0 and s[first - 1] != '\L': dec first
  s.selected = (first, s.cursor.int)

proc setCursorFromMouse*(s: var SynEdit; x, y, clickCount: int) =
  s.mouseX = x
  s.mouseY = y
  s.clicks = clickCount
  if clickCount < 2:
    s.selected.b = -1

# ---------------------------------------------------------------------------
# draw: input handling + rendering (immediate mode)
# ---------------------------------------------------------------------------

proc draw*(s: var SynEdit; e: Event; area: Rect) =
  # --- input handling ---
  case e.kind
  of TextInputEvent:
    if s.focused:
      var text = ""
      for c in e.text:
        if c == '\0': break
        text.add c
      if text.len > 0:
        for c in text:
          s.insertChar(c)

  of KeyDownEvent:
    if s.focused:
      let ctrl = CtrlPressed in e.mods
      let shift = ShiftPressed in e.mods

      case e.key
      of KeyLeft:
        if shift: s.selectLeft(ctrl)
        else: s.deselect(); s.left(ctrl)
      of KeyRight:
        if shift: s.selectRight(ctrl)
        else: s.deselect(); s.right(ctrl)
      of KeyUp:
        if shift: s.selectUp(false)
        elif ctrl: s.scrollLines(-3)
        else: s.deselect(); s.up(false)
      of KeyDown:
        if shift: s.selectDown(false)
        elif ctrl: s.scrollLines(3)
        else: s.deselect(); s.down(false)
      of KeyHome:
        if shift:
          let old = s.cursor.int
          s.home()
          s.select(old, s.cursor.int, true)
        else:
          s.deselect(); s.home()
      of KeyEnd:
        if shift:
          let old = s.cursor.int
          s.`end`()
          s.select(old, s.cursor.int, false)
        else:
          s.deselect(); s.`end`()
      of KeyPageUp:
        s.deselect(); s.pageUp()
      of KeyPageDown:
        s.deselect(); s.pageDown()
      of KeyBackspace:
        s.backspace(smartIndent = not ctrl)
      of KeyDelete:
        s.deleteKey()
      of KeyEnter:
        s.insertEnter(smartIndent = true)
      of KeyTab:
        if shift: s.dedent()
        else: s.indent()
      of KeyA:
        if ctrl: s.selectAll()
      of KeyZ:
        if ctrl:
          if shift: s.redo()
          else: s.undo()
      of KeyY:
        if ctrl: s.redo()
      of KeyC:
        if ctrl:
          let text = s.getSelectedText()
          if text.len > 0: putClipboardText(text)
      of KeyX:
        if ctrl:
          let text = s.getSelectedText()
          if text.len > 0:
            putClipboardText(text)
            s.removeSelectedText()
      of KeyV:
        if ctrl:
          let text = getClipboardText()
          if text.len > 0: s.insertText(text)
      else: discard

  of MouseDownEvent:
    if area.contains(point(e.x, e.y)):
      s.focused = true
      if e.clicks >= 3:
        s.setCursorFromMouse(e.x, e.y, 1)
        s.mouseSelectWholeLine()
      elif e.clicks == 2:
        s.setCursorFromMouse(e.x, e.y, 1)
        s.mouseSelectCurrentToken()
      else:
        s.setCursorFromMouse(e.x, e.y, e.clicks)
    else:
      s.focused = false

  of MouseWheelEvent:
    if s.focused:
      s.scrollLines(-e.y * 3)

  else: discard

  # --- rendering ---
  s.highlightIncrementally()

  s.cursorDim.h = 0
  let endY = area.y + area.h - 1
  let endX = area.x + area.w - 1
  var dim = area
  dim.w = endX
  dim.h = endY

  fillRect(area, s.theme.bg)

  let spl = s.spaceForLines()
  if s.showLineNumbers:
    dim.x = area.x + spl + 4

  var renderLine = s.firstLine
  var i = s.firstLineOffset.int
  s.span = 0

  let lineH = fontLineSkip(s.font)
  let fontSize = lineH

  # cursor: show when focused and cursor is in an editable position
  let showCursor = s.focused and s.readOnly < s.cursor.int
  var blink = false
  if showCursor:
    let ticks = getTicks()
    if ticks - s.lastBlinkTick > 500:
      s.cursorVisible = not s.cursorVisible
      s.lastBlinkTick = ticks
    blink = s.cursorVisible

  while dim.y + fontSize < endY and i <= s.len:
    if s.showLineNumbers:
      let num = $(renderLine + 1)
      let numColor = if renderLine == s.currentLine: s.theme.fg[TokenClass.None]
                     else: s.theme.lineNumColor
      discard drawText(s.font, area.x + 2, dim.y, num, numColor, s.theme.bg)

    i = s.drawTextLine(i, dim, blink)
    inc s.span
    inc renderLine

  while dim.y + fontSize < endY:
    inc dim.y, lineH
    inc s.span

  if s.clicks > 0:
    s.cursor = min(i, s.len).Natural
    s.setCurrentLine()
    s.clicks = 0
    s.cursorMoved()

