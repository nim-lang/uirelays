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
##   var ed = createSynEdit(font)
##   # uses `defaultTheme()` by default
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
##
## List of clickable lines -- a field where a click acts instead of just
## placing the cursor. The frame is the affordance; what a click does is up
## to the caller::
##
##   var tabs = createSynEdit(font)
##   tabs.setActionLines(0)     # every line is clickable
##   tabs.setCloseButtons(0)    # ... and closable
##   # setActionLines(1) would leave line 0 as a normal field
##   # in your main loop:
##   let act = tabs.draw(e, area, focused)
##   if act.kind == closeLine: tabs.gotoLine(act.line + 1, 0); tabs.deleteLine()

import ../uirelays/[coords, screen, input]
import ./theme
import ./langs/markdown
import std/strutils
export theme
export markdown

const
  LinkMod* = when defined(macosx): GuiPressed else: CtrlPressed

# ---------------------------------------------------------------------------
# Source languages
# ---------------------------------------------------------------------------

type
  SourceLanguage* = enum
    langNone, langNim, langCpp, langCsharp, langC, langJava, langJs,
    langXml, langHtml, langConsole, langPython, langRust, langMarkdown

  RenderFlag* = enum
    rfMarkdownImages,   ## Render Markdown image lines: ![alt](path)
    rfColorLiterals     ## Draw color chips for #RGB/#RRGGBB/#RRGGBBAA

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
    langConsole: {},
    langPython: {':'},
    langRust: {'(', '[', '{'},
    langMarkdown: {}]

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
  of ".py", ".pyw": langPython
  of ".rs": langRust
  of ".md", ".markdown": langMarkdown
  else: langNone

# ---------------------------------------------------------------------------
# Gap buffer types
# ---------------------------------------------------------------------------

type
  Cell* = object
    c*: char
    s*: TokenClass

  ActionKind = enum
    ## Undo grouping: consecutive keystrokes accumulate into a single Action
    ## as long as the kind stays `ins` or `dele`. When whitespace is typed
    ## (or deleted), the kind is promoted to `insFinished`/`delFinished`,
    ## which breaks the chain -- so "hello world" becomes two undo groups:
    ## "hello" and " world". This gives word-wise undo granularity without
    ## any explicit word detection.
    ins, insFinished, dele, delFinished

  Action = object
    k: ActionKind
    pos: int      ## buffer position where the action started
    version: int  ## groups compound ops (e.g. indent = N inserts);
                  ## undo/redo walks all actions sharing the same version
    word: string  ## the accumulated text inserted or deleted

  Indexer = object
    version: int
    currentlyIndexing: int
    position: int

  Marker = object
    a, b: int             ## buffer range [a..b] to highlight
    color: Color          ## background color for this marker

  LineDecoration = object
    line: int             ## line number (0-based)
    color: Color          ## color indicator shown in the line number gutter

  EditActionKind* = enum
    noAction,
    ctrlHover,          ## ctrl+mouse move over text
    ctrlClick,          ## ctrl+click on text
    closeLine           ## the (x) button of a line was clicked

  EditAction* = object
    case kind*: EditActionKind
    of noAction: discard
    of ctrlHover, ctrlClick:
      pos*: int         ## buffer offset
    of closeLine:
      line*: int        ## 0-based line whose (x) was clicked

  ImageCacheEntry = object
    path: string
    img: Image

  SynEdit* = object
    # Gap buffer
    front, back: seq[Cell]
    cursor: Natural
    # Line tracking
    firstLine*, currentLine*, numberOfLines: Natural
    firstLineOffset: Natural
    span*: int
    desiredCol: Natural
    # Selection
    selected: tuple[a, b: int]
    # Undo
    actions: seq[Action]
    undoIdx: int
    version: int
    cacheId: int
    # Rendering
    font: Font
    theme*: Theme
    flags*: set[RenderFlag]
    showLineNumbers*: bool
    cursorVisible: bool
    lastBlinkTick: int
    cursorDim: tuple[x, y, h: int]
    # Text
    tabSize*: int
    lang*: SourceLanguage
    changed: bool
    readOnly*: int                  ## -1 = fully editable;
                                    ## >= 0 = positions <= readOnly are protected
    # Bracket matching
    bracketA, bracketB: int
    # Underline (set by the app via underline())
    hotLink*: tuple[a, b: int]      ## buffer range to draw underlined
                                    ## (-1, -1) = no underline
    # Ctrl+hover probe
    probeX, probeY: int             ## screen coords for hover probe
    probeActive: bool               ## a probe is pending
    probeResult*: int               ## resolved buffer offset after render; -1 if none
    # Mouse
    mouseX, mouseY, clicks: int
    mouseDragging: bool
    dragStartPos: int
    # Scrollbar
    scrollGrabbed: bool
    scrollGrabOffset: int
    # Highlighting
    highlighter: Indexer
    # Markers (search results, etc.)
    markers: seq[Marker]
    # Line decorations (breakpoints, active execution line, etc.)
    lineDecorations: seq[LineDecoration]
    # Action lines -- see setActionLines()
    actionLines*: int               ## first line whose text is framed as
                                    ## clickable; -1 = none
    # Close buttons -- see setCloseButtons()
    closeLines*: int                ## first line with an (x) button; -1 = none
    closeHover: int                 ## line whose (x) the mouse is over; -1 = none
    # Cached images for rich markdown rendering
    imageCache: seq[ImageCacheEntry]
    # Cache
    offsetToLineCache: array[20, tuple[version, offset, line: int]]

# ---------------------------------------------------------------------------
# Public read-only accessors
# ---------------------------------------------------------------------------

proc currentLine*(s: SynEdit): int {.inline.} = s.currentLine.int
proc currentCol*(s: SynEdit): int {.inline.} = s.desiredCol.int
proc changed*(s: SynEdit): bool {.inline.} = s.changed
proc markChanged*(s: var SynEdit) = s.changed = true
proc markSaved*(s: var SynEdit) = s.changed = false
  ## Clear the changed flag without writing a file, for buffers whose content
  ## has been consumed by something other than `saveToFile`.
proc cursor*(s: SynEdit): int {.inline.} = s.cursor.int
proc cacheId*(s: SynEdit): int {.inline.} = s.cacheId
proc textVersion*(s: SynEdit): int {.inline.} = s.version
  ## Bumped by every editing operation. Something that walks the text and
  ## caches what it found -- a word index, an outline -- compares this against
  ## the version it last saw to know whether its answer is still current.
proc cursorRect*(s: SynEdit): tuple[x, y, h: int] {.inline.} = s.cursorDim
  ## Where the caret was drawn last, in screen coordinates, for a popup that
  ## wants to sit under it. `h == 0` means the caret was not on screen -- the
  ## buffer has scrolled away from it, or nothing has been rendered yet.
proc getFont*(s: SynEdit): Font {.inline.} = s.font
proc setFont*(s: var SynEdit; f: Font) {.inline.} = s.font = f
proc setRenderFlag*(s: var SynEdit; flag: RenderFlag; enabled = true) =
  if enabled: s.flags.incl flag
  else: s.flags.excl flag


# ---------------------------------------------------------------------------
# Gap buffer access
# ---------------------------------------------------------------------------

proc getCell(s: SynEdit; i: Natural): Cell {.inline.} =
  if i < s.front.len:
    s.front[i]
  else:
    let j = i - s.front.len
    if j <= s.back.high:
      s.back[s.back.high - j]
    else:
      Cell(c: '\L')

proc setCellStyle(s: var SynEdit; i: Natural; tc: TokenClass) =
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

proc graphemeLen(s: SynEdit; i: Natural): Positive =
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

proc `[]`(p: ptr SynEdit; i: Natural): char {.inline.} = p[][i]
proc len(p: ptr SynEdit): int {.inline.} = p[].len

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

  cKeywords = ["_Bool", "_Complex", "_Imaginary", "auto",
    "break", "case", "char", "const", "continue", "default", "do", "double",
    "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int",
    "long", "register", "restrict", "return", "short", "signed", "sizeof",
    "static", "struct", "switch", "typedef", "union", "unsigned", "void",
    "volatile", "while"]

  cppKeywords = ["asm", "auto", "break", "case", "catch",
    "char", "class", "const", "continue", "default", "delete", "do", "double",
    "else", "enum", "extern", "false", "float", "for", "friend", "goto", "if",
    "inline", "int", "long", "mutable", "namespace", "new", "operator",
    "private", "protected", "public", "register", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "template", "this", "throw", "true",
    "try", "typedef", "typename", "union", "unsigned", "using", "virtual",
    "void", "volatile", "while"]

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

  pythonKeywords = ["False", "None", "True", "and", "as", "assert", "async",
    "await", "break", "class", "continue", "def", "del", "elif", "else",
    "except", "finally", "for", "from", "global", "if", "import", "in",
    "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
    "try", "while", "with", "yield"]

  rustKeywords = ["as", "break", "const", "continue", "crate", "else", "enum",
    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
    "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
    "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
    "where", "while"]

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
  while pos < g.buf.len:
    case g.buf[pos]
    of '#':
      if isDoc:
        if g.buf[pos+1] == '#' and g.buf[pos+2] == '[': inc nesting
      elif g.buf[pos+1] == '[': inc nesting
      inc pos
    of ']':
      if isDoc:
        if g.buf[pos+1] == '#' and g.buf[pos+2] == '#':
          if nesting == 0: inc(pos, 3); break
          dec nesting
      elif g.buf[pos+1] == '#':
        if nesting == 0: inc(pos, 2); break
        dec nesting
      inc pos
    else: inc pos
  result = pos

proc nimNumberPostfix(g: var GeneralTokenizer; position: int): int =
  var pos = position
  if g.buf[pos] == '\'': inc(pos)
  case g.buf[pos]
  of 'd', 'D': g.kind = TokenClass.FloatNumber; inc(pos)
  of 'f', 'F':
    g.kind = TokenClass.FloatNumber; inc(pos)
    if g.buf[pos] in {'0'..'9'}: inc(pos)
    if g.buf[pos] in {'0'..'9'}: inc(pos)
  of 'i', 'I', 'u', 'U':
    inc(pos)
    if g.buf[pos] in {'0'..'9'}: inc(pos)
    if g.buf[pos] in {'0'..'9'}: inc(pos)
  else: discard
  result = pos

proc nimNumber(g: var GeneralTokenizer; position: int): int =
  const decChars = {'0'..'9', '_'}
  var pos = position
  g.kind = TokenClass.DecNumber
  while g.buf[pos] in decChars: inc(pos)
  if g.buf[pos] == '.':
    if g.buf[pos+1] == '.': return pos
    g.kind = TokenClass.FloatNumber; inc(pos)
    while g.buf[pos] in decChars: inc(pos)
  if g.buf[pos] in {'e', 'E'}:
    g.kind = TokenClass.FloatNumber; inc(pos)
    if g.buf[pos] in {'+', '-'}: inc(pos)
    while g.buf[pos] in decChars: inc(pos)
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
    while pos < g.buf.len:
      case g.buf[pos]
      of '\\':
        g.kind = TokenClass.EscapeSequence; inc(pos)
        case g.buf[pos]
        of 'x', 'X': inc(pos); (if g.buf[pos] in hexChars: inc(pos)); (if g.buf[pos] in hexChars: inc(pos))
        of '0'..'9': (while g.buf[pos] in {'0'..'9'}: inc(pos))
        else: inc(pos)
        break
      of '\L', '\C': g.state = TokenClass.None; break
      of '\"': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  elif g.state == TokenClass.LongStringLit:
    g.kind = TokenClass.LongStringLit
    while pos < g.buf.len:
      if g.buf[pos] == '\"':
        inc(pos)
        if g.buf[pos] == '\"' and g.buf[pos+1] == '\"' and g.buf[pos+2] != '\"':
          inc(pos, 2); break
      else: inc(pos)
    g.state = TokenClass.None
  elif g.state in {TokenClass.LongComment, TokenClass.Comment}:
    g.kind = g.state
    pos = nimMultilineComment(g, pos, g.kind == TokenClass.LongComment)
    g.state = TokenClass.None
  else:
    case g.buf[pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf.len and g.buf[pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '#':
      if g.buf[pos+1] == '#':
        g.kind = TokenClass.LongComment; inc pos
      else: g.kind = TokenClass.Comment
      if g.buf[pos+1] == '[':
        g.state = g.kind
        pos = nimMultilineComment(g, pos+2, g.kind == TokenClass.LongComment)
        g.state = TokenClass.None
      else:
        while g.buf[pos] != '\L': inc(pos)
    of 'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[pos] in SymChars + {'_'}:
        add(id, g.buf[pos]); inc(pos)
      if g.buf[pos] == '\"':
        if g.buf[pos+1] == '\"' and g.buf[pos+2] == '\"':
          inc(pos, 3)
          g.kind = TokenClass.LongStringLit
          while pos < g.buf.len:
            if g.buf[pos] == '\"':
              inc(pos)
              if g.buf[pos] == '\"' and g.buf[pos+1] == '\"' and g.buf[pos+2] != '\"':
                inc(pos, 2); break
            else: inc(pos)
        else:
          g.kind = TokenClass.RawData; inc(pos)
          while g.buf[pos] != '\L':
            if g.buf[pos] == '"' and g.buf[pos+1] != '"': break
            inc(pos)
          if g.buf[pos] == '\"': inc(pos)
      else:
        g.kind = nimGetKeyword(id)
    of '0':
      inc(pos)
      case g.buf[pos]
      of 'b', 'B': inc(pos); (while g.buf[pos] in binChars: inc(pos)); pos = nimNumberPostfix(g, pos)
      of 'x', 'X': inc(pos); (while g.buf[pos] in hexChars: inc(pos)); pos = nimNumberPostfix(g, pos)
      of 'o', 'O': inc(pos); (while g.buf[pos] in octChars: inc(pos)); pos = nimNumberPostfix(g, pos)
      else: pos = nimNumber(g, pos)
    of '1'..'9': pos = nimNumber(g, pos)
    of '\'':
      inc(pos); g.kind = TokenClass.CharLit
      while true:
        case g.buf[pos]
        of '\L': break
        of '\'': inc(pos); break
        of '\\': inc(pos, 2)
        else: inc(pos)
    of '\"':
      inc(pos)
      if g.buf[pos] == '\"' and g.buf[pos+1] == '\"':
        inc(pos, 2)
        g.kind = TokenClass.LongStringLit
        while pos < g.buf.len:
          if g.buf[pos] == '\"':
            inc(pos)
            if g.buf[pos] == '\"' and g.buf[pos+1] == '\"' and g.buf[pos+2] != '\"':
              inc(pos, 2); break
          else: inc(pos)
      else:
        g.kind = TokenClass.StringLit
        while true:
          case g.buf[pos]
          of '\L': break
          of '\"': inc(pos); break
          of '\\': g.state = g.kind; break
          else: inc(pos)
    of '(', '[', '{':
      inc(pos); g.kind = TokenClass.Punctuation
      if g.buf[pos] == '.' and g.buf[pos+1] != '.': inc pos
    of ')', ']', '}', '`', ':', ',', ';':
      inc(pos); g.kind = TokenClass.Punctuation
    of '.':
      if g.buf[pos+1] in {')', ']', '}'}:
        inc(pos, 2); g.kind = TokenClass.Punctuation
      else: g.kind = TokenClass.Operator; inc pos
    else:
      if g.buf[pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[pos] in OpChars: inc(pos)
      else:
        if pos < g.buf.len: inc(pos)
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
      case g.buf[pos]
      of '\\':
        g.kind = TokenClass.EscapeSequence; inc(pos)
        case g.buf[pos]
        of 'x', 'X': inc(pos); (if g.buf[pos] in hexChars: inc(pos)); (if g.buf[pos] in hexChars: inc(pos))
        of '0'..'9': (while g.buf[pos] in {'0'..'9'}: inc(pos))
        else: inc(pos)
        break
      of '\L': g.state = TokenClass.None; break
      of '"': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  elif g.state == TokenClass.LongComment:
    var nested = 0
    g.kind = TokenClass.LongComment
    while pos < g.buf.len:
      case g.buf[pos]
      of '*': inc(pos); (if g.buf[pos] == '/': inc(pos); (if nested == 0: break))
      of '/': inc(pos); (if g.buf[pos] == '*': inc(pos))
      else: inc(pos)
    g.state = TokenClass.None
  else:
    case g.buf[pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf.len and g.buf[pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '/':
      inc(pos)
      if g.buf[pos] == '/':
        g.kind = TokenClass.Comment
        while g.buf[pos] != '\L': inc(pos)
      elif g.buf[pos] == '*':
        g.kind = TokenClass.LongComment; inc(pos)
        while pos < g.buf.len:
          case g.buf[pos]
          of '*': inc(pos); (if g.buf[pos] == '/': inc(pos); break)
          else: inc(pos)
      else: g.kind = TokenClass.Operator
    of '#':
      inc(pos); g.kind = TokenClass.Preprocessor
      while g.buf[pos] in {' ', '\t'}: inc(pos)
      while g.buf[pos] in symChars: inc(pos)
    of 'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[pos] in symChars: add(id, g.buf[pos]); inc(pos)
      g.kind = TokenClass.Identifier
      for kw in keywords:
        if kw == id: g.kind = TokenClass.Keyword; break
    of '0':
      inc(pos)
      case g.buf[pos]
      of 'b', 'B': inc(pos); (while g.buf[pos] in binChars: inc(pos))
      of 'x', 'X': inc(pos); (while g.buf[pos] in hexChars: inc(pos))
      of '0'..'7': inc(pos); (while g.buf[pos] in octChars: inc(pos))
      else:
        g.kind = TokenClass.DecNumber
        while g.buf[pos] in {'0'..'9'}: inc(pos)
    of '1'..'9':
      g.kind = TokenClass.DecNumber
      while g.buf[pos] in {'0'..'9'}: inc(pos)
    of '\'':
      g.kind = TokenClass.CharLit
      inc(pos)
      while g.buf[pos] notin {'\L', '\''}: inc(pos)
      if g.buf[pos] == '\'': inc(pos)
    of '"':
      inc(pos); g.kind = TokenClass.StringLit
      while pos < g.buf.len:
        case g.buf[pos]
        of '"': inc(pos); break
        of '\\': g.state = g.kind; break
        else: inc(pos)
    of '(', ')', '[', ']', '{', '}', ':', ',', ';', '.':
      inc(pos); g.kind = TokenClass.Punctuation
    else:
      if g.buf[pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[pos] in OpChars: inc(pos)
      else:
        if pos < g.buf.len: inc(pos)
        g.kind = TokenClass.None
  g.length = pos - g.pos
  g.pos = pos

proc pythonNextToken(g: var GeneralTokenizer) =
  const
    hexChars = {'0'..'9', 'A'..'F', 'a'..'f'}
    symChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '\x80'..'\xFF'}
  var pos = g.pos
  g.start = g.pos
  if g.state == TokenClass.StringLit:
    g.kind = TokenClass.StringLit
    while true:
      case g.buf[pos]
      of '\\':
        g.kind = TokenClass.EscapeSequence; inc(pos)
        case g.buf[pos]
        of 'x', 'X': inc(pos); (if g.buf[pos] in hexChars: inc(pos)); (if g.buf[pos] in hexChars: inc(pos))
        of '0'..'9': (while g.buf[pos] in {'0'..'9'}: inc(pos))
        else: inc(pos)
        break
      of '\L': g.state = TokenClass.None; break
      of '"', '\'': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  else:
    case g.buf[pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf.len and g.buf[pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '#':
      g.kind = TokenClass.Comment
      while g.buf[pos] != '\L': inc(pos)
    of 'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[pos] in symChars: add(id, g.buf[pos]); inc(pos)
      g.kind = TokenClass.Identifier
      for kw in pythonKeywords:
        if kw == id: g.kind = TokenClass.Keyword; break
    of '0':
      inc(pos)
      case g.buf[pos]
      of 'x', 'X': inc(pos); (while g.buf[pos] in hexChars: inc(pos))
      of '0'..'9':
        g.kind = TokenClass.DecNumber
        while g.buf[pos] in {'0'..'9'}: inc(pos)
      else:
        g.kind = TokenClass.DecNumber
        while g.buf[pos] in {'0'..'9'}: inc(pos)
    of '1'..'9':
      g.kind = TokenClass.DecNumber
      while g.buf[pos] in {'0'..'9'}: inc(pos)
    of '"', '\'':
      inc(pos); g.kind = TokenClass.StringLit
      while pos < g.buf.len:
        case g.buf[pos]
        of '"', '\'': inc(pos); break
        of '\\': g.state = g.kind; break
        else: inc(pos)
    of '(', ')', '[', ']', '{', '}', ':', ',', ';', '.':
      inc(pos); g.kind = TokenClass.Punctuation
    else:
      if g.buf[pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[pos] in OpChars: inc(pos)
      else:
        if pos < g.buf.len: inc(pos)
        g.kind = TokenClass.None
  g.length = pos - g.pos
  g.pos = pos

proc rustNextToken(g: var GeneralTokenizer) =
  const
    hexChars = {'0'..'9', 'A'..'F', 'a'..'f'}
    symChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '\x80'..'\xFF'}
  var pos = g.pos
  g.start = g.pos
  if g.state == TokenClass.StringLit:
    g.kind = TokenClass.StringLit
    while true:
      case g.buf[pos]
      of '\\':
        g.kind = TokenClass.EscapeSequence; inc(pos)
        case g.buf[pos]
        of 'x', 'X': inc(pos); (if g.buf[pos] in hexChars: inc(pos)); (if g.buf[pos] in hexChars: inc(pos))
        of '0'..'9': (while g.buf[pos] in {'0'..'9'}: inc(pos))
        else: inc(pos)
        break
      of '\L': g.state = TokenClass.None; break
      of '"': inc(pos); g.state = TokenClass.None; break
      else: inc(pos)
  else:
    case g.buf[pos]
    of ' ', '\x09'..'\x0D':
      g.kind = TokenClass.Whitespace
      while pos < g.buf.len and g.buf[pos] in {' ', '\x09'..'\x0D'}: inc(pos)
    of '/':
      inc(pos)
      if g.buf[pos] == '/':
        g.kind = TokenClass.Comment
        while g.buf[pos] != '\L': inc(pos)
      elif g.buf[pos] == '*':
        g.kind = TokenClass.LongComment; inc(pos)
        while pos < g.buf.len:
          case g.buf[pos]
          of '*': inc(pos); (if g.buf[pos] == '/': inc(pos); break)
          else: inc(pos)
      else: g.kind = TokenClass.Operator
    of 'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF':
      var id = ""
      while g.buf[pos] in symChars: add(id, g.buf[pos]); inc(pos)
      g.kind = TokenClass.Identifier
      for kw in rustKeywords:
        if kw == id: g.kind = TokenClass.Keyword; break
    of '0':
      inc(pos)
      case g.buf[pos]
      of 'x', 'X': inc(pos); (while g.buf[pos] in hexChars: inc(pos))
      else:
        g.kind = TokenClass.DecNumber
        while g.buf[pos] in {'0'..'9'}: inc(pos)
    of '1'..'9':
      g.kind = TokenClass.DecNumber
      while g.buf[pos] in {'0'..'9'}: inc(pos)
    of '\'':
      g.kind = TokenClass.CharLit
      inc(pos)
      while g.buf[pos] notin {'\L', '\''}: inc(pos)
      if g.buf[pos] == '\'': inc(pos)
    of '"':
      inc(pos); g.kind = TokenClass.StringLit
      while pos < g.buf.len:
        case g.buf[pos]
        of '"': inc(pos); break
        of '\\': g.state = g.kind; break
        else: inc(pos)
    of '(', ')', '[', ']', '{', '}', ':', ',', ';', '.':
      inc(pos); g.kind = TokenClass.Punctuation
    else:
      if g.buf[pos] in OpChars:
        g.kind = TokenClass.Operator
        while g.buf[pos] in OpChars: inc(pos)
      else:
        if pos < g.buf.len: inc(pos)
        g.kind = TokenClass.None
  g.length = pos - g.pos
  g.pos = pos

proc getNextToken(g: var GeneralTokenizer; lang: SourceLanguage) =
  case lang
  of langNone, langConsole:
    g.start = g.pos
    if g.pos < g.buf.len: inc g.pos
    g.kind = TokenClass.None
    g.length = g.pos - g.start
  of langNim: nimNextToken(g)
  of langCpp: clikeNextToken(g, cppKeywords)
  of langC: clikeNextToken(g, cKeywords)
  of langJs: clikeNextToken(g, jsKeywords)
  of langJava: clikeNextToken(g, jsKeywords)
  of langCsharp: clikeNextToken(g, cppKeywords)
  of langPython: pythonNextToken(g)
  of langRust: rustNextToken(g)
  of langXml, langHtml:
    g.start = g.pos
    if g.pos < g.buf.len: inc g.pos
    g.kind = TokenClass.None
    g.length = g.pos - g.start
  of langMarkdown:
    g.start = g.pos
    if g.pos < g.buf.len: inc g.pos
    g.kind = TokenClass.Text
    g.length = g.pos - g.start

proc strToLanguage*(s: string): SourceLanguage =
  case s.toLowerAscii()
  of "nim", "nims", "nimble": langNim
  of "c": langC
  of "cpp", "cxx", "c++", "hpp": langCpp
  of "cs", "csharp", "c#": langCsharp
  of "java": langJava
  of "js", "javascript", "jsx": langJs
  of "py", "python": langPython
  of "rs", "rust": langRust
  of "xml": langXml
  of "html", "htm": langHtml
  of "md", "markdown": langMarkdown
  else: langNone

proc styleMarkdownLink(s: var SynEdit; lineEnd: int; i: var int): bool =
  ## Style `[label](url)` or `![alt](url)` starting at `i`. Advances `i`.
  let bang = s[i] == '!' and i + 1 < lineEnd and s[i + 1] == '['
  let openBracket = if bang: i + 1 else: i
  if openBracket >= lineEnd or s[openBracket] != '[': return false
  var j = openBracket + 1
  while j < lineEnd and s[j] != ']': inc j
  if j >= lineEnd or j + 1 >= lineEnd or s[j + 1] != '(': return false
  var k = j + 2
  while k < lineEnd and s[k] != ')' and s[k] != ' ': inc k
  var close = k
  while close < lineEnd and s[close] != ')': inc close
  if close >= lineEnd: return false
  if bang:
    s.setCellStyle(i, TokenClass.Punctuation)
  s.setCellStyle(openBracket, TokenClass.Punctuation)
  for p in openBracket + 1 ..< j:
    s.setCellStyle(p, TokenClass.Link)
  s.setCellStyle(j, TokenClass.Punctuation)
  s.setCellStyle(j + 1, TokenClass.Punctuation)
  for p in j + 2 ..< close:
    s.setCellStyle(p, TokenClass.Comment)
  s.setCellStyle(close, TokenClass.Punctuation)
  i = close + 1
  result = true

proc styleMarkdownLine(s: var SynEdit; lineStart, lineEnd, last: int) =
  ## Headings, links, autolinks and inline code -- the bits that make a
  ## markdown buffer readable without leaving the editor.
  var i = lineStart
  while i < lineEnd and s[i] in {' ', '\t'}:
    s.setCellStyle(i, TokenClass.Whitespace)
    inc i
  var hashes = 0
  var h = i
  while h < lineEnd and s[h] == '#':
    inc hashes
    inc h
  if hashes in 1 .. 6 and h < lineEnd and s[h] == ' ':
    for p in i ..< h:
      s.setCellStyle(p, TokenClass.Punctuation)
    while h < lineEnd and s[h] == ' ':
      s.setCellStyle(h, TokenClass.Whitespace)
      inc h
    for p in h ..< min(lineEnd, last + 1):
      s.setCellStyle(p, TokenClass.Keyword)
    if lineEnd <= last:
      s.setCellStyle(lineEnd, TokenClass.None)
    return

  for p in lineStart ..< min(lineEnd, last + 1):
    s.setCellStyle(p, TokenClass.Text)
  i = lineStart
  while i < lineEnd:
    if s[i] == '`':
      var j = i + 1
      while j < lineEnd and s[j] != '`': inc j
      if j < lineEnd:
        s.setCellStyle(i, TokenClass.Punctuation)
        for p in i + 1 ..< j:
          s.setCellStyle(p, TokenClass.StringLit)
        s.setCellStyle(j, TokenClass.Punctuation)
        i = j + 1
        continue
    if s[i] == '<' and i + 1 < lineEnd and s[i + 1] notin {' ', '\t', '<'}:
      var j = i + 1
      while j < lineEnd and s[j] notin {'>', ' ', '\t'}: inc j
      if j < lineEnd and s[j] == '>':
        s.setCellStyle(i, TokenClass.Punctuation)
        for p in i + 1 ..< j:
          s.setCellStyle(p, TokenClass.Link)
        s.setCellStyle(j, TokenClass.Punctuation)
        i = j + 1
        continue
    if s[i] == '[' or (s[i] == '!' and i + 1 < lineEnd and s[i + 1] == '['):
      if s.styleMarkdownLink(lineEnd, i):
        continue
    inc i
  if lineEnd <= last:
    s.setCellStyle(lineEnd, TokenClass.None)

proc highlightMarkdown(s: var SynEdit; first, last: int) =
  var insideFence = false
  var fenceLang = langNone
  var pos = first
  while pos > 0 and s[pos-1] != '\L': dec pos
  while pos <= last:
    var lineStart = pos
    var lineEnd = pos
    while lineEnd <= last and s[lineEnd] != '\L': inc lineEnd

    var lineText = ""
    for j in lineStart..<lineEnd:
      lineText.add s[j]

    let stripped = lineText.strip(leading = true, trailing = false)
    if stripped.startsWith("```") or stripped.startsWith("~~~"):
      for j in lineStart..<min(lineEnd, last+1):
        s.setCellStyle(j, TokenClass.MarkdownFence)
      let rest = stripped[3..^1].strip
      if rest.len > 0 and not insideFence:
        fenceLang = strToLanguage(rest)
        insideFence = true
      elif insideFence:
        insideFence = false
        fenceLang = langNone
    elif insideFence and fenceLang != langNone:
      var g: GeneralTokenizer
      g.buf = addr s
      g.kind = low(TokenClass)
      g.start = lineStart
      g.length = 0
      g.state = TokenClass.None
      g.pos = lineStart
      while g.pos < lineEnd and g.pos <= last:
        getNextToken(g, fenceLang)
        if g.length == 0: break
        for k in 0 ..< g.length:
          if g.start + k <= last:
            s.setCellStyle(g.start + k, g.kind)
      if lineEnd <= last:
        s.setCellStyle(lineEnd, TokenClass.None)
    else:
      s.styleMarkdownLine(lineStart, lineEnd, last)

    pos = lineEnd + 1

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
  if s.lang == langMarkdown:
    s.highlightMarkdown(0, s.len - 1)
    return
  var i = oldCursor.int
  while i >= 1 and s[i-1] != '\L': dec i
  let first = i
  i = s.cursor
  while s[i] != '\L': inc i
  let last = i
  let initialState = if first == 0: TokenClass.None else: s.getCell(first-1).s
  s.highlight(first, last, initialState)

proc highlightEverything(s: var SynEdit) =
  if s.lang == langNone: return
  if s.lang == langMarkdown:
    s.highlightMarkdown(0, s.len - 1)
  else:
    s.highlight(0, s.len - 1, TokenClass.None)

proc highlightIncrementally(s: var SynEdit) =
  if s.lang == langNone or s.highlighter.version == s.version: return
  if s.lang == langMarkdown:
    s.highlightMarkdown(0, s.len - 1)
    s.highlighter.version = s.version
    return
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

proc scrollLines(s: var SynEdit; amount: int) =
  let oldFirstLine = s.firstLine
  s.firstLine = clamp(s.firstLine.int + amount, 0, max(0, s.numberOfLines.int - 1)).Natural
  var a = s.firstLine.int - oldFirstLine.int
  if a < 0:
    while a < 0: s.upFirstLineOffset(); inc a
  elif a > 0:
    while a > 0: s.downFirstLineOffset(); dec a

proc wheelScroll*(s: var SynEdit; delta: int) =
  ## Scroll by one turn of the mouse wheel: three lines per notch, and the
  ## sign is the wheel's, so a positive delta scrolls towards the top of the
  ## text. Public because a wheel event carries only its delta -- an app that
  ## wants the panel *under the pointer* to scroll, rather than the focused
  ## one, has to route the event itself, and this is what it routes it to.
  s.scrollLines(-delta * 3)

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
  # Accumulate consecutive backspaces into one Action while the cursor
  # is contiguous and the previous action was also a non-finished delete.
  if ah == -1 or s.actions[ah].k != dele or s.actions[ah].pos != oldCursor.int:
    s.actions.setLen(ah + 2)
    inc ah
    s.actions[ah].word = ""
    s.actions[ah].k = dele
    s.actions[ah].version = s.version
  s.rawBackspace(overrideUtf8, s.actions[ah].word)
  s.actions[ah].pos = s.cursor
  s.edit()
  # Deleting whitespace promotes to delFinished, breaking the group.
  if s.actions[ah].word.len == 1 and s.actions[ah].word[0] in Whitespace:
    s.actions[ah].k = delFinished
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)

proc insertNoSelect(s: var SynEdit; text: string; singleUndoOp = false) =
  if s.cursor.int <= s.readOnly or text.len == 0: return
  let oldCursor = s.cursor
  s.prepareForEdit()
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  # Accumulate consecutive inserts into one Action while the cursor is
  # contiguous (pos matches) and the previous action was `ins` (not yet
  # finished). Typing "hello" is one Action; the space after it promotes
  # to `insFinished`, so "hello world" = two undo groups.
  if s.actions.len > 0 and s.actions[^1].k == ins and
     s.actions[^1].pos == oldCursor.int - s.actions[^1].word.len and not singleUndoOp:
    s.actions[^1].word.add text.filterForInsert
  else:
    s.actions.add(Action(k: ins, pos: s.cursor, word: text.filterForInsert,
                         version: s.version))
  # Whitespace or explicit singleUndoOp breaks the accumulation chain.
  if text[^1] in Whitespace or singleUndoOp: s.actions[^1].k = insFinished
  s.edit()
  s.rawInsert(text)
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)

proc gotoPos*(s: var SynEdit; pos: int) =
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
  ## Undo all actions sharing the same version number in one step.
  ## Compound operations like indent (which emit N inserts) share a
  ## version, so they undo atomically. Within a single version,
  ## each Action's `word` is the accumulated text from the grouping
  ## logic above -- so one "undo" reverses an entire word of typing.
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

proc left(s: var SynEdit; jump: bool) =
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

proc right(s: var SynEdit; jump: bool) =
  s.rawRight()
  if jump:
    if s[s.cursor] in Letters:
      while s.cursor < s.len and s[s.cursor] in Letters: s.rawRight()
    else:
      while s.cursor < s.len and s[s.cursor] notin Letters and
            s[s.cursor] != '\L':
        s.rawRight()
  s.cursorMoved()

proc up(s: var SynEdit; jump: bool) =
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

proc down(s: var SynEdit; jump: bool) =
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

proc home(s: var SynEdit) =
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

proc `end`(s: var SynEdit) =
  while s.cursor < s.len and s[s.cursor] != '\L':
    s.cursor += 1
  s.desiredCol = s.getColumn().Natural
  s.cursorMoved()

proc pageUp(s: var SynEdit) =
  let lines = max(1, s.span - 2)
  for i in 1..lines: s.up(false)

proc pageDown(s: var SynEdit) =
  let lines = max(1, s.span - 2)
  for i in 1..lines: s.down(false)

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

proc selectAll(s: var SynEdit) =
  s.selected = (0, s.len - 1)

proc deselect(s: var SynEdit) {.inline.} =
  s.selected.b = -1

proc getSelectedText*(s: SynEdit): string =
  if s.selected.b < 0: return ""
  result = newStringOfCap(s.selected.b - s.selected.a + 1)
  for i in s.selected.a .. s.selected.b:
    result.add s[i]

proc removeSelectedText(s: var SynEdit) =
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

proc selectLeft(s: var SynEdit; jump: bool) =
  if s.cursor > 0:
    let old = s.cursor.int
    s.left(jump)
    s.select(old, s.cursor, true)

proc selectRight(s: var SynEdit; jump: bool) =
  if s.cursor < s.len:
    let old = s.cursor.int
    s.right(jump)
    s.select(old, s.cursor, false)

proc selectUp(s: var SynEdit; jump: bool) =
  if s.cursor > 0:
    let old = s.cursor.int
    s.up(jump)
    s.select(old, s.cursor, true)

proc selectDown(s: var SynEdit; jump: bool) =
  if s.cursor < s.len:
    let old = s.cursor.int
    s.down(jump)
    s.select(old, s.cursor, false)

# ---------------------------------------------------------------------------
# High-level editing
# ---------------------------------------------------------------------------

proc insertChar*(s: var SynEdit; c: char) =
  # Each high-level editing operation increments `version`. All Actions
  # created within the same call share that version number, so undo
  # reverses them as a unit. For simple typing this is one Action per
  # call; for indent/dedent it can be many.
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

proc getWordPrefix*(s: SynEdit): string =
  ## The identifier the cursor sits directly behind, "" when it sits behind
  ## anything else. This is what a completion completes.
  var i = s.cursor.int
  while i > 0 and s[i - 1] in Letters: dec i
  result = newStringOfCap(s.cursor.int - i)
  for j in i ..< s.cursor.int: result.add s[j]

proc getSpanPrefix*(s: SynEdit; tokens: int): tuple[text: string; start: int] =
  ## The last `tokens` tokens before the cursor, verbatim -- the text a
  ## multi-token completion completes, and the offset it begins at. A token is
  ## an identifier or a single character of punctuation, and the space between
  ## them comes along as it was written, so what is returned is exactly what is
  ## in the buffer rather than a normalization of it.
  ##
  ## The walk stops at the start of the line: a suggestion that reached back
  ## over a line break would be completing something the eye does not read as
  ## one thing. Asking for more tokens than the line has is therefore not an
  ## error -- it yields the line so far.
  let cursor = s.cursor.int
  var lineStart = cursor
  while lineStart > 0 and s[lineStart - 1] != '\L': dec lineStart
  var start = cursor
  var left = tokens
  while left > 0:
    var i = start
    while i > lineStart and s[i - 1] in {' ', '\t'}: dec i
    if i <= lineStart: break
    if s[i - 1] in Letters:
      while i > lineStart and s[i - 1] in Letters: dec i
    else:
      dec i
    start = i
    dec left
  result.start = start
  result.text = newStringOfCap(cursor - start)
  for j in start ..< cursor: result.text.add s[j]

proc replaceSpan*(s: var SynEdit; start: int; text: string) =
  ## Swap the buffer range `start ..< cursor` for `text`. Everything this
  ## touches shares one `version`, so Ctrl+Z takes the whole swap back in one
  ## step instead of one character at a time -- which is the entire reason a
  ## completion goes through here rather than through `insertText`.
  let cursor = s.cursor.int
  if start < 0 or start > cursor: return
  let n = cursor - start
  if n == 0 and text.len == 0: return
  inc s.version
  s.deselect()
  # Without this the first backspace would be appended to whatever deletion
  # came before it -- an action of an older version, which would tear the
  # group in two.
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  if s.actions.len > 0 and s.actions[^1].k == dele:
    s.actions[^1].k = delFinished
  for i in 0 ..< n: s.backspaceNoSelect(overrideUtf8 = true)
  if text.len > 0: s.insertNoSelect(text, singleUndoOp = true)
  s.cursorMoved()

proc replaceWordPrefix*(s: var SynEdit; word: string) =
  ## Swap the identifier the cursor sits behind for `word` -- what accepting a
  ## single-word completion does.
  let prefix = s.getWordPrefix()
  if word.len == 0 or word == prefix: return
  s.replaceSpan(s.cursor.int - prefix.len, word)

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

proc deleteKey(s: var SynEdit) =
  if s.selected.b < 0:
    if s.cursor >= s.len: return
    let L = s.lastRuneLen(s.cursor.int + 1)
    s.cursor = (s.cursor.int + L).Natural
    s.setCurrentLine()
    s.backspace(false)
  else:
    s.removeSelectedText()
  s.cursorMoved()

proc insertEnter(s: var SynEdit; smartIndent = true) =
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

proc indent(s: var SynEdit) =
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

proc dedent(s: var SynEdit) =
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
  # `numberOfLines` counts the line breaks, so it *is* the index of the last
  # line -- the same bound `currentLine` is clamped to everywhere else. Taking
  # one off here made the last line unreachable, which is why the (x) on the
  # bottom row of the tab list used to close the row above it.
  let line = clamp(line - 1, 0, s.numberOfLines.int)
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

proc getLineCount*(s: SynEdit): int =
  s.numberOfLines.int + 1

proc getLineText*(s: SynEdit; lineIdx: int): string =
  let start = s.getLineOffset(lineIdx)
  var i = start
  while i < s.len and s[i] != '\L': inc i
  result = newStringOfCap(i - start)
  for j in start ..< i: result.add s[j]

proc deleteSelection*(s: var SynEdit) =
  if s.selected.b >= 0:
    s.removeSelectedText()

proc selectLine*(s: var SynEdit) =
  inc s.version
  let lineStart = s.getLineOffset(s.currentLine.int)
  var lineEnd = lineStart
  while lineEnd < s.len and s[lineEnd] != '\L': inc lineEnd
  s.selected = (lineStart, lineEnd - 1)
  s.cursor = lineEnd.Natural
  s.desiredCol = s.getColumn().Natural

proc deleteLine*(s: var SynEdit) =
  inc s.version
  let lineStart = s.getLineOffset(s.currentLine.int)
  var lineEnd = lineStart
  while lineEnd < s.len and s[lineEnd] != '\L': inc lineEnd
  # include the trailing newline if present
  let delEnd = if lineEnd < s.len: lineEnd else: lineEnd - 1
  # The last line has no newline of its own, so it takes the one in front of
  # it instead. Otherwise deleting it would leave an empty row where it was,
  # and a list whose rows are its contents -- the tab list, the history panel
  # -- would keep a row nothing is behind.
  let stop = if lineEnd < s.len: lineStart else: max(0, lineStart - 1)
  s.cursor = (delEnd + 1).Natural
  s.setCurrentLine()
  let oldCursor = s.cursor
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  s.actions.add(Action(k: delFinished, pos: s.cursor, word: "", version: s.version))
  s.edit()
  while s.cursor.int > stop and s.cursor > 0:
    if s.cursor.int - 1 <= s.readOnly: break
    s.prepareForEdit()
    s.rawBackspace(overrideUtf8 = true, s.actions[^1].word)
    s.actions[^1].pos = s.cursor
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)
  s.selected.b = -1

proc duplicateLine*(s: var SynEdit) =
  inc s.version
  let lineText = s.getLineText(s.currentLine.int)
  let lineStart = s.getLineOffset(s.currentLine.int)
  var lineEnd = lineStart
  while lineEnd < s.len and s[lineEnd] != '\L': inc lineEnd
  s.gotoPos(lineEnd)
  s.prepareForEdit()
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  s.actions.add(Action(k: insFinished, pos: s.cursor, word: "", version: s.version))
  s.edit()
  let toInsert = "\L" & lineText
  s.rawInsert(toInsert)
  s.actions[^1].word = toInsert
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(s.cursor)

proc moveLineUp*(s: var SynEdit) =
  if s.currentLine.int == 0: return
  inc s.version
  let curLine = s.currentLine.int
  let curText = s.getLineText(curLine)
  let prevText = s.getLineText(curLine - 1)
  let prevStart = s.getLineOffset(curLine - 1)
  var prevEnd = prevStart
  while prevEnd < s.len and s[prevEnd] != '\L': inc prevEnd
  var curEnd = prevEnd + 1
  while curEnd < s.len and s[curEnd] != '\L': inc curEnd
  # delete both lines + newline between them, reinsert swapped
  s.cursor = (curEnd).Natural
  s.setCurrentLine()
  let oldCursor = s.cursor
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  s.actions.add(Action(k: delFinished, pos: s.cursor, word: "", version: s.version))
  s.edit()
  while s.cursor.int > prevStart and s.cursor > 0:
    if s.cursor.int - 1 <= s.readOnly: break
    s.prepareForEdit()
    s.rawBackspace(overrideUtf8 = true, s.actions[^1].word)
    s.actions[^1].pos = s.cursor
  # now insert swapped
  let swapped = curText & "\L" & prevText
  s.actions.add(Action(k: insFinished, pos: s.cursor, word: swapped, version: s.version))
  s.edit()
  s.prepareForEdit()
  s.rawInsert(swapped)
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)
  s.selected.b = -1
  s.gotoPos(s.getLineOffset(curLine - 1))

proc moveLineDown*(s: var SynEdit) =
  if s.currentLine.int >= s.numberOfLines.int: return
  inc s.version
  let curLine = s.currentLine.int
  let curText = s.getLineText(curLine)
  let nextText = s.getLineText(curLine + 1)
  let curStart = s.getLineOffset(curLine)
  var curEnd = curStart
  while curEnd < s.len and s[curEnd] != '\L': inc curEnd
  var nextEnd = curEnd + 1
  while nextEnd < s.len and s[nextEnd] != '\L': inc nextEnd
  s.cursor = (nextEnd).Natural
  s.setCurrentLine()
  let oldCursor = s.cursor
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  s.actions.add(Action(k: delFinished, pos: s.cursor, word: "", version: s.version))
  s.edit()
  while s.cursor.int > curStart and s.cursor > 0:
    if s.cursor.int - 1 <= s.readOnly: break
    s.prepareForEdit()
    s.rawBackspace(overrideUtf8 = true, s.actions[^1].word)
    s.actions[^1].pos = s.cursor
  let swapped = nextText & "\L" & curText
  s.actions.add(Action(k: insFinished, pos: s.cursor, word: swapped, version: s.version))
  s.edit()
  s.prepareForEdit()
  s.rawInsert(swapped)
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)
  s.selected.b = -1
  s.gotoPos(s.getLineOffset(curLine + 1))

proc insertLineAbove*(s: var SynEdit) =
  inc s.version
  let lineStart = s.getLineOffset(s.currentLine.int)
  s.gotoPos(lineStart)
  s.prepareForEdit()
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  let toInsert = "\L"
  s.actions.add(Action(k: insFinished, pos: s.cursor, word: toInsert, version: s.version))
  s.edit()
  s.rawInsert(toInsert)
  # move cursor back to the new blank line
  s.gotoPos(lineStart)
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(s.cursor)

proc insertLineBelow*(s: var SynEdit) =
  inc s.version
  var lineEnd = s.getLineOffset(s.currentLine.int)
  while lineEnd < s.len and s[lineEnd] != '\L': inc lineEnd
  s.gotoPos(lineEnd)
  s.prepareForEdit()
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  let toInsert = "\L"
  s.actions.add(Action(k: insFinished, pos: s.cursor, word: toInsert, version: s.version))
  s.edit()
  s.rawInsert(toInsert)
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(s.cursor)

proc joinLines*(s: var SynEdit) =
  if s.currentLine.int >= s.numberOfLines.int: return
  inc s.version
  var lineEnd = s.getLineOffset(s.currentLine.int)
  while lineEnd < s.len and s[lineEnd] != '\L': inc lineEnd
  if lineEnd >= s.len: return
  # position after the newline
  let afterNl = lineEnd + 1
  # find start of next line content (skip leading spaces)
  var nextContent = afterNl
  while nextContent < s.len and s[nextContent] == ' ': inc nextContent
  # delete from lineEnd to nextContent (newline + leading spaces), insert single space
  s.cursor = nextContent.Natural
  s.setCurrentLine()
  let oldCursor = s.cursor
  s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
  s.actions.add(Action(k: delFinished, pos: s.cursor, word: "", version: s.version))
  s.edit()
  while s.cursor.int > lineEnd and s.cursor > 0:
    s.prepareForEdit()
    s.rawBackspace(overrideUtf8 = true, s.actions[^1].word)
    s.actions[^1].pos = s.cursor
  # insert a single space separator
  s.actions.add(Action(k: insFinished, pos: s.cursor, word: " ", version: s.version))
  s.edit()
  s.prepareForEdit()
  s.rawInsert(" ")
  s.desiredCol = s.getColumn().Natural
  s.highlightLine(oldCursor)

proc toggleComment*(s: var SynEdit) =
  inc s.version
  let prefix = case s.lang
    of langNim: "# "
    of langC, langCpp, langCsharp, langJs, langJava, langRust: "// "
    of langPython: "# "
    else: "# "
  let lineStart = s.getLineOffset(s.currentLine.int)
  # check if line already starts with the comment prefix
  var i = lineStart
  while i < s.len and s[i] == ' ': inc i  # skip indent
  var hasComment = true
  for j in 0 ..< prefix.len:
    if i + j >= s.len or s[i + j] != prefix[j]:
      hasComment = false
      break
  if hasComment:
    # remove the prefix
    s.cursor = (i + prefix.len).Natural
    s.setCurrentLine()
    let oldCursor = s.cursor
    s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
    s.actions.add(Action(k: delFinished, pos: s.cursor, word: "", version: s.version))
    s.edit()
    while s.cursor.int > i and s.cursor > 0:
      s.prepareForEdit()
      s.rawBackspace(overrideUtf8 = true, s.actions[^1].word)
      s.actions[^1].pos = s.cursor
    s.desiredCol = s.getColumn().Natural
    s.highlightLine(oldCursor)
  else:
    # insert prefix at indent level
    s.gotoPos(i)
    s.prepareForEdit()
    s.actions.setLen(clamp(s.undoIdx + 1, 0, s.actions.len))
    s.actions.add(Action(k: insFinished, pos: s.cursor, word: prefix, version: s.version))
    s.edit()
    s.rawInsert(prefix)
    s.desiredCol = s.getColumn().Natural
    s.highlightLine(s.cursor)



# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------

proc fullText*(s: SynEdit): string =
  result = newStringOfCap(s.front.len + s.back.len)
  for i in 0 ..< s.front.len: result.add s.front[i].c
  for i in countdown(s.back.len - 1, 0): result.add s.back[i].c

proc clear*(s: var SynEdit) =
  for entry in s.imageCache:
    if entry.img != Image(0):
      freeImage(entry.img)
  s.imageCache.setLen 0
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

proc isBinary(text: string): bool =
  let check = min(text.len, 8192)
  for i in 0 ..< check:
    if text[i] == '\0': return true

proc loadFromFile*(s: var SynEdit; filename: string) =
  let text = readFile(filename)
  if text.isBinary: return
  s.setText(text)

proc saveToFile*(s: var SynEdit; filename: string) =
  writeFile(filename, s.fullText)
  s.changed = false

proc appendOutput*(s: var SynEdit; text: string) =
  ## Append text and mark everything as read-only up to the end.
  ## For terminal/console use: output is protected, user types after it.
  s.readOnly = -1
  s.gotoPos(s.len)
  s.prepareForEdit()
  s.rawInsert(text)
  s.highlightLine(s.cursor)
  s.readOnly = s.len - 1

proc setLabel*(s: var SynEdit; text: string) =
  ## Set text and make the entire buffer read-only. For labels and status bars.
  s.readOnly = -1
  s.setText(text)
  s.readOnly = s.len - 1

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

proc createSynEdit*(font: Font; theme = defaultTheme()): SynEdit =
  result = SynEdit(front: @[], back: @[], actions: @[], cursor: 0,
    selected: (-1, -1), bracketA: -1, bracketB: -1, hotLink: (-1, -1),
    readOnly: -1, tabSize: TabWidth, lang: langNim,
    actionLines: -1, closeLines: -1, closeHover: -1,
    font: font, theme: theme, flags: {},
    showLineNumbers: false, cursorVisible: true, lastBlinkTick: 0)

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

proc textWidth(font: Font; text: string): int =
  measureText(font, text).w

proc hexDigitValue(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc isHexDigit(c: char): bool {.inline.} =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc tryParseHexColor(text: openArray[char]; start: int; c: var Color; consumed: var int): bool =
  ## Parse #RGB/#RRGGBB/#RRGGBBAA from text[start..].
  if start < 0 or start >= text.len or text[start] != '#':
    return
  var j = start + 1
  while j < text.len and isHexDigit(text[j]) and (j - start) <= 8:
    inc j
  let n = j - (start + 1)
  if not (n == 3 or n == 6 or n == 8):
    return

  template pairVal(pos: int): int =
    ((hexDigitValue(text[pos]) shl 4) or hexDigitValue(text[pos + 1]))

  if n == 3:
    let r = hexDigitValue(text[start + 1])
    let g = hexDigitValue(text[start + 2])
    let b = hexDigitValue(text[start + 3])
    if r < 0 or g < 0 or b < 0:
      return
    c = color(uint8(r * 17), uint8(g * 17), uint8(b * 17))
  else:
    let r = pairVal(start + 1)
    let g = pairVal(start + 3)
    let b = pairVal(start + 5)
    if r < 0 or g < 0 or b < 0:
      return
    if n == 8:
      let a = pairVal(start + 7)
      if a < 0: return
      c = color(uint8(r), uint8(g), uint8(b), uint8(a))
    else:
      c = color(uint8(r), uint8(g), uint8(b))
  consumed = n + 1
  result = true

proc getCachedImage(s: var SynEdit; path: string): Image =
  for e in s.imageCache:
    if e.path == path:
      return e.img
  let img = loadImage(path)
  s.imageCache.add ImageCacheEntry(path: path, img: img)
  result = img

proc extractMarkdownLink*(s: SynEdit; pos: int): tuple[url: string; a, b: int] =
  ## Buffer-position variant of `findMarkdownLinkAt`.
  result = ("", -1, -1)
  if pos < 0 or pos >= s.len: return
  var lineStart = pos
  while lineStart > 0 and s[lineStart - 1] != '\L': dec lineStart
  var lineEnd = pos
  while lineEnd < s.len and s[lineEnd] != '\L': inc lineEnd
  var line = newStringOfCap(lineEnd - lineStart)
  for p in lineStart ..< lineEnd: line.add s[p]
  let hit = findMarkdownLinkAt(line, pos - lineStart)
  if hit.a < 0: return
  result = (hit.url, lineStart + hit.a, lineStart + hit.b)

proc gotoMarkdownHeading*(s: var SynEdit; fragment: string): bool =
  ## Jump to the first ATX heading whose slug matches `fragment`.
  let want = markdownHeadingSlug(fragment)
  if want.len == 0: return false
  var i = 0
  var lineNo = 0
  while i <= s.len:
    let lineStart = i
    while i < s.len and s[i] != '\L': inc i
    var j = lineStart
    while j < i and s[j] in {' ', '\t'}: inc j
    var hashes = 0
    while j < i and s[j] == '#':
      inc hashes
      inc j
    if hashes in 1 .. 6 and j < i and s[j] == ' ':
      while j < i and s[j] == ' ': inc j
      var title = ""
      for p in j ..< i: title.add s[p]
      if markdownHeadingSlug(title) == want:
        s.gotoLine(lineNo + 1, 0)
        return true
    if i >= s.len: break
    inc i
    inc lineNo

proc renderMarkdownImageLine(
    s: var SynEdit; lineStart: int; dim: var Rect;
    endX, endY, lineH: int; showCursor: bool;
    nextIndex, consumedRows: var int): bool =
  ## Render markdown image block for a single source line.
  var j = lineStart
  while j < s.len and s[j] != '\L': inc j

  var line = newStringOfCap(max(0, j - lineStart))
  for p in lineStart ..< j:
    line.add s[p]

  var imgPath = ""
  if not parseMarkdownImagePath(line, imgPath):
    return

  # Keep source visible while actively editing this line.
  if showCursor and lineStart <= s.cursor.int and s.cursor.int <= j:
    return

  let maxW = endX - dim.x - 4
  let maxH = endY - dim.y - 2
  if maxW <= 16 or maxH < lineH:
    return

  let imgH = min(max(lineH * 6, lineH * 2), maxH)
  let dst = rect(dim.x, dim.y + 1, maxW, imgH)
  let img = s.getCachedImage(imgPath)
  if img != Image(0):
    drawImage(img, rect(0, 0, dst.w, dst.h), dst)
  else:
    # Backends without image relays still show a useful placeholder.
    fillRect(dst, color(52, 56, 64))
    drawLine(dst.x, dst.y, dst.x + dst.w - 1, dst.y + dst.h - 1, color(140, 146, 172))
    drawLine(dst.x + dst.w - 1, dst.y, dst.x, dst.y + dst.h - 1, color(140, 146, 172))
    discard drawText(s.font, dst.x + 6, dst.y + 4, imgPath, color(220, 220, 220), color(52, 56, 64))

  dim.y += imgH + 2
  nextIndex = j + 1
  consumedRows = max(1, (imgH + lineH - 1) div lineH)
  result = true

proc spaceForLines(s: SynEdit): int =
  if s.showLineNumbers:
    let n = s.numberOfLines + 1
    result = textWidth(s.font, $n) + 8
  else:
    result = 0

proc getBg(s: SynEdit; i: int): Color =
  if i <= s.selected.b and s.selected.a <= i: return s.theme.selBg
  if i == s.bracketA or i == s.bracketB: return s.theme.bracketBg
  for m in s.markers:
    if m.a <= i and i <= m.b: return m.color
  return s.theme.bg

proc underline*(s: var SynEdit; a, b: int) =
  ## Set the underline range. Call before the draw/render that should show it.
  ## Pass (-1, -1) to clear.
  s.hotLink = (a, b)

# ---------------------------------------------------------------------------
# Markers -- highlighted buffer ranges (search results, diagnostics, etc.)
# ---------------------------------------------------------------------------

proc addMarker*(s: var SynEdit; a, b: int; color: Color) =
  ## Add a highlighted range [a..b] with the given background color.
  s.markers.add Marker(a: a, b: b, color: color)

proc clearMarkers*(s: var SynEdit) =
  ## Remove all markers.
  s.markers.setLen 0

# ---------------------------------------------------------------------------
# Line decorations -- gutter indicators (breakpoints, active line, etc.)
# ---------------------------------------------------------------------------

proc setLineDecoration*(s: var SynEdit; line: int; color: Color) =
  ## Set a colored indicator for the given line number in the gutter.
  for i in 0 ..< s.lineDecorations.len:
    if s.lineDecorations[i].line == line:
      s.lineDecorations[i].color = color
      return
  s.lineDecorations.add LineDecoration(line: line, color: color)

proc clearLineDecoration*(s: var SynEdit; line: int) =
  ## Remove the decoration for a specific line.
  for i in 0 ..< s.lineDecorations.len:
    if s.lineDecorations[i].line == line:
      s.lineDecorations.del(i)
      return

proc clearLineDecorations*(s: var SynEdit) =
  ## Remove all line decorations.
  s.lineDecorations.setLen 0

# ---------------------------------------------------------------------------
# Action lines -- lines that act on click instead of just taking the cursor
# ---------------------------------------------------------------------------

proc setActionLines*(s: var SynEdit; first: int) =
  ## Frame the text of every line from `first` on, marking it as clickable:
  ## in such a field a click does something (activate, open, navigate)
  ## rather than merely placing the cursor. Pass `first = -1` to disable.
  ## Survives `setText`, so a field can be declared clickable once.
  ## The frame is drawn in `theme.actionColor`.
  s.actionLines = first

proc setCloseButtons*(s: var SynEdit; first: int) =
  ## Draw an (x) button at the right edge of every line from `first` on.
  ## Clicking one yields `EditAction(kind: closeLine, line: ...)` and leaves
  ## the cursor alone, so it does not double as an activating click.
  ## Pass `first = -1` to disable. Survives `setText`.
  ## The button is drawn in `theme.closeColor`.
  s.closeLines = first

proc closeButtonWidth(s: SynEdit): int {.inline.} =
  fontLineSkip(s.font) - 1

proc drawFrame(r: Rect; color: Color) =
  if r.w <= 0 or r.h <= 0: return
  fillRect(rect(r.x, r.y, r.w, 1), color)
  fillRect(rect(r.x, r.y + r.h - 1, r.w, 1), color)
  fillRect(rect(r.x, r.y, 1, r.h), color)
  fillRect(rect(r.x + r.w - 1, r.y, 1, r.h), color)

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
  # mouse click handling: find the character within the token
  if db.s[].clicks > 0:
    let p = point(db.s[].mouseX, db.s[].mouseY)
    if d.contains(p):
      # measure incrementally to find which char the click lands on
      var best = ra
      var prefix = ""
      for k in ra .. rb:
        prefix.add db.chars[k]
        if d.x + textWidth(db.font, prefix) > db.s[].mouseX:
          break
        best = k + 1
      if best > rb + 1: best = rb + 1
      db.s[].cursor = db.toCursor[min(best, rb + 1)].Natural
      db.s[].setCurrentLine()
      db.s[].clicks = 0
      db.s[].cursorMoved()
      if db.s[].mouseDragging:
        if db.s[].dragStartPos < 0:
          db.s[].dragStartPos = db.s[].cursor.int
        else:
          let a = min(db.s[].dragStartPos, db.s[].cursor.int)
          let b = max(db.s[].dragStartPos, db.s[].cursor.int)
          if a == b: db.s[].selected = (a, -1)
          else: db.s[].selected = (a, b - 1)
  # Ctrl+hover probe: resolve screen coords to buffer position
  if db.s[].probeActive and db.s[].probeResult < 0:
    let p = point(db.s[].probeX, db.s[].probeY)
    if d.contains(p):
      var best = ra
      var prefix = ""
      for k in ra .. rb:
        prefix.add db.chars[k]
        if d.x + textWidth(db.font, prefix) > db.s[].probeX:
          break
        best = k + 1
      if best > rb + 1: best = rb + 1
      db.s[].probeResult = db.toCursor[min(best, rb)]
  # Underline range (set externally via underline())
  let hl = db.s[].hotLink
  let isLink = hl.a >= 0 and db.toCursor[ra] <= hl.b and db.toCursor[rb] >= hl.a
  let fgColor = if isLink: db.s[].theme.cursorColor else: fg
  discard drawText(db.font, d.x, d.y, db.tempStr, fgColor, bg)
  if isLink:
    let ulY = d.y + db.lineH - 1
    drawLine(d.x, ulY, d.x + textWidth(db.font, db.tempStr), ulY, fgColor)

proc drawRun(db: var DrawBuf; a, b: int; fg, bg: Color) =
  ## Draw `db.chars[a..b]` at the current position, wrapping if it does not fit.
  if a > b: return
  db.tempStr.setLen 0
  for k in a..b: db.tempStr.add db.chars[k]
  let ext = measureText(db.font, db.tempStr)
  let w = ext.w
  if db.dim.x + w + db.spaceWidth <= db.dim.w:
    drawSubtoken(db, a, b, fg, bg)
    db.dim.x += w
  else:
    # wrapping: just draw what fits, then continue on next line
    var ra = a
    while ra <= b:
      var probe = ra
      while probe <= b:
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
      if ra <= b:
        db.dim.x = db.oldX
        db.dim.y += db.lineH
        if db.dim.y + db.lineH > db.maxY: break

proc drawColorChip(db: var DrawBuf; c: Color): int =
  ## Draw the chip at the current position, return the width it occupies.
  let chipSize = max(6, db.lineH - 6)
  let x = db.dim.x + 2
  let y = db.dim.y + (db.lineH - chipSize) div 2
  if x + chipSize + 2 > db.dim.w: return 0
  fillRect(rect(x, y, chipSize, chipSize), c)
  drawLine(x, y, x + chipSize, y, color(30, 30, 30))
  drawLine(x, y, x, y + chipSize, color(30, 30, 30))
  drawLine(x + chipSize, y, x + chipSize, y + chipSize, color(30, 30, 30))
  drawLine(x, y + chipSize, x + chipSize, y + chipSize, color(30, 30, 30))
  result = chipSize + 4

proc drawToken(db: var DrawBuf; tc: TokenClass; fg, bg: Color) =
  if db.dim.y + db.lineH > db.maxY: return
  # The face the theme asks for, for this token class only: `styledFont` opens
  # it the first time it is needed and hands back the same handle afterwards,
  # so this costs a lookup per token, not an open. A family without the face
  # gives the upright font back, and the token is simply drawn plain.
  db.font = styledFont(db.s[].font, db.s[].theme.style[tc])
  if rfColorLiterals notin db.s[].flags:
    db.drawRun(0, db.charsLen - 1, fg, bg)
    return
  # A color chip is drawn right behind its literal, so the token is split into
  # runs at every literal and the rest of the text is shifted to the right.
  # Anything else either covers the character following the literal or puts
  # the chip far away from it, at the end of the token.
  var runStart = 0
  var idx = 0
  while idx < db.charsLen:
    var chipColor: Color
    var consumed = 0
    if db.chars[idx] == '#' and
       tryParseHexColor(db.chars.toOpenArray(0, db.charsLen - 1), idx,
                        chipColor, consumed):
      var last = idx + consumed - 1
      # keep the closing quote of `"#RRGGBB"` with the literal
      if last + 1 < db.charsLen and db.chars[last + 1] in {'"', '\''}:
        inc last
      db.drawRun(runStart, last, fg, bg)
      db.dim.x += db.drawColorChip(chipColor)
      runStart = last + 1
      idx = last + 1
    else:
      inc idx
  db.drawRun(runStart, db.charsLen - 1, fg, bg)

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
            db.drawToken(tokenClass, s.theme.fg[tokenClass], styleBg)
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
        db.drawToken(tokenClass, s.theme.fg[tokenClass], styleBg)
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
  s.clicks = 0
  s.cursorMoved()

proc mouseSelectWholeLine(s: var SynEdit) =
  var first = s.cursor.int
  while first > 0 and s[first - 1] != '\L': dec first
  s.selected = (first, s.cursor.int)
  s.clicks = 0

proc setCursorFromMouse(s: var SynEdit; x, y, clickCount: int) =
  s.mouseX = x
  s.mouseY = y
  s.clicks = clickCount
  if clickCount < 2 and not s.mouseDragging:
    s.selected.b = -1

# ---------------------------------------------------------------------------
# draw: input handling + rendering (immediate mode)
# ---------------------------------------------------------------------------

const ScrollBarWidth* = 14

proc scrollEnabled(s: SynEdit): bool {.inline.} =
  s.span > 0 and s.span.Natural <= s.numberOfLines

proc closeButtonHit(s: SynEdit; area: Rect; x, y: int): int =
  ## The line whose (x) button covers (x, y), or -1. The button column is
  ## derived from the area alone, so this answers before the line is drawn.
  result = -1
  if s.closeLines < 0 or not area.contains(point(x, y)): return
  let lineH = fontLineSkip(s.font)
  if lineH <= 0: return
  let endX = area.x + area.w -
             (if s.scrollEnabled: ScrollBarWidth else: 0) - 1
  if x < endX - s.closeButtonWidth or x > endX: return
  let line = s.firstLine.int + (y - area.y) div lineH
  if line < s.closeLines or line >= s.getLineCount(): return
  if s.getLineText(line).len == 0: return   # an empty line has no button
  result = line

proc scrollGrip(s: SynEdit; area: Rect; lineH: int): Rect =
  ## Compute the scrollbar grip rectangle.
  if not s.scrollEnabled: return
  let totalLines = s.numberOfLines.int + s.span
  let contentH = float(totalLines * lineH)
  let trackH = float(area.h - 2)
  let ratio = float(area.h) / contentH
  let gripH = clamp(int(trackH * ratio), 20, int(trackH))
  let scrollArea = trackH - float(gripH)
  let maxScroll = float(totalLines - s.span)
  let posRatio = if maxScroll > 0: float(s.firstLine) / maxScroll else: 0.0
  let gripY = clamp(int(scrollArea * posRatio) + area.y + 1,
                     area.y + 1, area.y + area.h - gripH - 1)
  result = rect(area.x + area.w - ScrollBarWidth, gripY,
                ScrollBarWidth - 2, gripH)

proc render*(s: var SynEdit; area: Rect; showCursor: bool) =
  ## Core rendering. Paints the buffer, optionally with a blinking cursor.
  let lineH = fontLineSkip(s.font)
  let hasScrollBar = s.scrollEnabled

  s.highlightIncrementally()

  s.cursorDim.h = 0
  let endY = area.y + area.h - 1
  let endX = area.x + area.w - (if hasScrollBar: ScrollBarWidth else: 0) - 1
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

  let fontSize = lineH

  var blink = false
  if showCursor and s.readOnly < s.cursor.int:
    let ticks = getTicks()
    if ticks - s.lastBlinkTick > 500:
      s.cursorVisible = not s.cursorVisible
      s.lastBlinkTick = ticks
    blink = s.cursorVisible

  while dim.y + fontSize < endY and i <= s.len:
    if s.showLineNumbers:
      let num = $(renderLine + 1)
      var numColor = if renderLine == s.currentLine: s.theme.fg[TokenClass.None]
                     else: s.theme.lineNumColor
      var numBg = s.theme.bg
      for ld in s.lineDecorations:
        if ld.line == renderLine.int:
          # Draw a thin vertical bar on the left edge instead of a square.
          # This matches standard editors (VS Code, etc.) and avoids jagged edges.
          fillRect(rect(area.x, dim.y, 3, lineH), ld.color)
          break
      discard drawText(s.font, area.x + 2, dim.y, num, numColor, numBg)

    var nextI = i
    var consumedRows = 1
    if rfMarkdownImages in s.flags:
      if s.renderMarkdownImageLine(i, dim, endX, endY, lineH, showCursor, nextI, consumedRows):
        i = nextI
        inc s.span, consumedRows
        inc renderLine
        continue

    let thisLine = renderLine.int
    let actionLine = s.actionLines >= 0 and thisLine >= s.actionLines
    let closeLine = s.closeLines >= 0 and thisLine >= s.closeLines
    let lineY = dim.y
    let lineStart = i
    i = s.drawTextLine(i, dim, blink)
    if actionLine or closeLine:
      # Drawn after the text, so the per-token backgrounds cannot paint over
      # the frame's top and bottom edges -- and so the button occludes a
      # name that is too long for the column.
      let empty = lineStart >= s.len or s[lineStart] == '\L'
      if not empty:
        if closeLine:
          let bw = s.closeButtonWidth
          let br = rect(endX - bw, lineY, bw, lineH - 1)
          let hovered = s.closeHover == thisLine
          # The cross is drawn, not typed: no font has to have the glyph.
          fillRect(br, if hovered: s.theme.closeColor else: s.getBg(lineStart))
          let fg = if hovered: s.theme.bg else: s.theme.closeColor
          let pad = max(3, bw div 4)
          let x0 = br.x + pad
          let x1 = br.x + br.w - 1 - pad
          let y0 = br.y + pad
          let y1 = br.y + br.h - 1 - pad
          drawLine(x0, y0, x1, y1, fg)
          drawLine(x1, y0, x0, y1, fg)
        if actionLine:
          # The frame outlines the whole row, so the row reads as one target
          # -- and drawing it last puts its edges over the button's fill.
          # lineH - 1 keeps consecutive frames from sharing an edge.
          drawFrame(rect(area.x, lineY, endX - area.x + 1, lineH - 1),
                    s.theme.actionColor)
    inc s.span, consumedRows
    inc renderLine

  while dim.y + fontSize < endY:
    inc dim.y, lineH
    inc s.span

  if s.clicks > 0:
    s.cursor = min(i, s.len).Natural
    s.setCurrentLine()
    s.clicks = 0
    s.cursorMoved()
    if s.mouseDragging:
      if s.dragStartPos < 0: s.dragStartPos = s.cursor.int
      else:
        let a = min(s.dragStartPos, s.cursor.int)
        let b = max(s.dragStartPos, s.cursor.int)
        if a == b: s.selected = (a, -1)
        else: s.selected = (a, b - 1)

  # draw scrollbar
  if hasScrollBar:
    let trackRect = rect(area.x + area.w - ScrollBarWidth, area.y,
                         ScrollBarWidth, area.h)
    fillRect(trackRect, s.theme.scrollTrackColor)
    let finalGrip = s.scrollGrip(area, lineH)
    let gripColor = if s.scrollGrabbed: s.theme.scrollBarActiveColor
                    else: s.theme.scrollBarColor
    fillRect(finalGrip, gripColor)

proc draw*(s: var SynEdit; e: Event; area: Rect; focused: bool): EditAction =
  ## Per-frame entry point. When focused, processes input and shows cursor.
  ## When not focused, just paints. Always returns an action (noAction if unfocused).
  let lineH = fontLineSkip(s.font)
  let grip = s.scrollGrip(area, lineH)
  let hasScrollBar = s.scrollEnabled
  let closeHit =
    if e.kind in {MouseDownEvent, MouseMoveEvent}:
      s.closeButtonHit(area, e.x, e.y)
    else: -1
  if e.kind == MouseMoveEvent: s.closeHover = closeHit

  case e.kind
  of TextInputEvent:
    if focused:
      var text = ""
      for c in e.text:
        if c == '\0': break
        text.add c
      if text.len > 0:
        for c in text:
          s.insertChar(c)

  of KeyDownEvent:
    if focused:
      let ctrl = CtrlPressed in e.mods or GuiPressed in e.mods
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
    if hasScrollBar and grip.contains(point(e.x, e.y)):
      s.scrollGrabbed = true
      s.scrollGrabOffset = e.y - grip.y
    elif closeHit >= 0:
      # Leave the cursor where it is: closing a line is not activating it.
      s.render(area, showCursor = focused)
      return EditAction(kind: closeLine, line: closeHit)
    elif area.contains(point(e.x, e.y)):
      if LinkMod in e.mods:
        s.setCursorFromMouse(e.x, e.y, 1)
      elif e.clicks >= 3:
        s.setCursorFromMouse(e.x, e.y, 1)
        s.mouseSelectWholeLine()
      elif e.clicks == 2:
        s.setCursorFromMouse(e.x, e.y, 1)
        s.mouseSelectCurrentToken()
      else:
        s.setCursorFromMouse(e.x, e.y, e.clicks)
        s.mouseDragging = true
        s.dragStartPos = -1

  of MouseUpEvent:
    s.scrollGrabbed = false
    s.mouseDragging = false

  of MouseMoveEvent:
    if (LinkMod in e.mods) and area.contains(point(e.x, e.y)):
      s.probeX = e.x
      s.probeY = e.y
      s.probeActive = true
      s.probeResult = -1
      if s.mouseDragging:
        s.mouseX = e.x
        s.mouseY = e.y
        s.clicks = 1
    else:
      s.probeActive = false
      s.probeResult = -1
      if s.mouseDragging:
        s.mouseDragging = false
    if s.scrollGrabbed and hasScrollBar:
      let trackH = float(area.h - 2)
      let totalLines = s.numberOfLines.int + s.span
      let ratio = float(area.h) / float(totalLines * lineH)
      let gripH = clamp(trackH * ratio, 20, trackH)
      let trackScrollArea = trackH - gripH
      if trackScrollArea > 0:
        let mouseRel = float(e.y - s.scrollGrabOffset - area.y - 1)
        let posRatio = clamp(mouseRel / trackScrollArea, 0.0, 1.0)
        let maxScroll = totalLines - s.span
        let target = clamp(int(posRatio * float(maxScroll)), 0, maxScroll)
        s.scrollLines(target - s.firstLine.int)

  of MouseWheelEvent:
    # Without the pointer's position in the event this is the best a widget can
    # do on its own; `wheelScroll` is how a host routes it by hover instead.
    if focused:
      s.wheelScroll(e.y)

  else: discard

  # Reset cursor blink on any input so the cursor stays visible while editing.
  if focused and e.kind != NoEvent:
    s.cursorVisible = true
    s.lastBlinkTick = getTicks()

  s.render(area, showCursor = focused)

  # After rendering, probe and click positions have been resolved.
  if e.kind == MouseDownEvent and (LinkMod in e.mods) and
     area.contains(point(e.x, e.y)):
    result = EditAction(kind: ctrlClick, pos: s.cursor.int)
  elif s.probeActive and s.probeResult >= 0:
    result = EditAction(kind: ctrlHover, pos: s.probeResult)
  elif s.probeActive and s.probeResult < 0:
    discard

