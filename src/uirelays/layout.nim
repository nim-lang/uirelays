# Layout manager: a NIF description -> named Rects.
#
# The layout is a tree of boxes:
#
#   (layout
#     (toolbar (lines 2))
#     (cols
#       (local (px 250))
#       (divider (px 4))
#       (remote))
#     (log (lines 5))
#     (status (lines 1)))
#
# * `(layout ...)` is the window; its children are stacked top to bottom.
# * `(rows ...)` stacks its children top to bottom, `(cols ...)` left to right,
#   and either may hold the other, so nesting replaces every special case.
# * Every other tag is a leaf and names a widget: `resolve` puts its `Rect`
#   under that name. Since there are no anonymous boxes -- a box that nothing
#   draws in is not worth mentioning -- the name can be the tag itself.
#
# `layout`, `rows`, `cols`, `px`, `lines` and `stretch` are therefore the only
# names a widget cannot have.
#
# A box may state its size along the axis its parent divides -- a height inside
# `rows`, a width inside `cols`:
#
#   (px 250)     250 of whatever unit the driver draws in
#   (lines 5)    5 * lineHeight, plus the padding above and below
#   (stretch 2)  two shares of what the fixed sizes leave over
#
# Leaving the size out means `(stretch 1)`.

import std/tables
import coords, tinynif

type
  SizeKind = enum
    skStretch,    ## weighted share of the remaining space
    skPixels,     ## fixed pixel count
    skLines       ## N * lineHeight

  CellSize = object
    kind: SizeKind
    value: int    ## stretch weight, pixels, or line count

  NodeKind = enum
    # `rows` first on purpose: a default-constructed Layout is then an empty
    # window rather than a nameless cell covering everything.
    nkRows,       ## children stacked top to bottom
    nkCols,       ## children placed left to right
    nkCell        ## a leaf: one named rect

  Node = object
    kind: NodeKind
    name: string          ## cells only
    size: CellSize        ## along the axis the parent divides
    children: seq[Node]   ## containers only

  Layout* = object
    root: Node
    error*: string   ## empty when the layout parsed; otherwise "line:col: why".
                     ## Parsing never raises, so this is the only report there
                     ## is -- and it is short enough for a status bar.

  CellHit* = object
    name*: string
    pos*: GlobalPos

# ---------------------------------------------------------------------------
# Parsing. tinynif hands out tags as strings; giving them meaning is this
# module's business, so the vocabulary lives here and nowhere else.
# ---------------------------------------------------------------------------

type
  LayoutTag = enum
    tagCell,      ## anything that is not one of the structural tags below
    tagLayout, tagRows, tagCols, tagPx, tagLines, tagStretch

  Parser = object
    lex: Lexer
    tok: Token
    error: string

proc toTag(s: string): LayoutTag =
  ## tinynif hands out tags as strings; this is the one place they turn into
  ## something this module knows. Every tag that is not structural names a
  ## cell, which is why there is no "unknown tag" here.
  case s
  of "layout": result = tagLayout
  of "rows": result = tagRows
  of "cols": result = tagCols
  of "px": result = tagPx
  of "lines": result = tagLines
  of "stretch": result = tagStretch
  else: result = tagCell

proc isSizeTag(s: string): bool =
  let t = toTag(s)
  result = t == tagPx or t == tagLines or t == tagStretch

proc fail(p: var Parser; msg: string) =
  ## The first complaint is the one that gets reported: everything after it is
  ## a consequence of it.
  if p.error.len == 0:
    p.error = p.tok.position & ": " & msg

proc advance(p: var Parser) =
  p.tok = next(p.lex)
  if p.tok.kind == tkError: p.fail p.tok.text

proc parseSize(p: var Parser): CellSize =
  ## `(px 250)`, `(lines 5)`, `(stretch 2)`.
  result = CellSize(kind: skStretch, value: 1)
  let tag = toTag(p.tok.text)
  p.advance
  if p.tok.kind != tkIntLit:
    p.fail "expected a number but found " & $p.tok
    return
  if p.tok.intVal < 0:
    p.fail "a size cannot be negative"
    return
  case tag
  of tagPx: result = CellSize(kind: skPixels, value: int(p.tok.intVal))
  of tagLines: result = CellSize(kind: skLines, value: int(p.tok.intVal))
  else: result = CellSize(kind: skStretch, value: int(p.tok.intVal))
  p.advance
  if p.tok.kind != tkParRi:
    p.fail "expected ')' after the size but found " & $p.tok
    return
  p.advance

proc parseNode(p: var Parser; isRoot: bool): Node =
  result = Node(kind: nkCell, name: "",
                size: CellSize(kind: skStretch, value: 1), children: @[])
  if p.tok.kind != tkParLe:
    p.fail "expected '(' but found " & $p.tok
    return
  case toTag(p.tok.text)
  of tagLayout:
    if not isRoot:
      p.fail "(layout ...) may only be the outermost tag; use (rows ...) here"
      return
    result.kind = nkRows
    p.advance
  of tagRows:
    result.kind = nkRows
    p.advance
  of tagCols:
    result.kind = nkCols
    p.advance
  of tagPx, tagLines, tagStretch:
    p.fail "'" & p.tok.text & "' is a size, not a box"
    return
  of tagCell:
    # Every other tag names a widget: `(history (lines 5))`.
    result.kind = nkCell
    result.name = p.tok.text
    p.advance
  if p.error.len > 0: return

  # The size comes before the children, so that it cannot hide in the middle
  # of a long list.
  var hasSize = false
  if p.tok.kind == tkParLe and isSizeTag(p.tok.text):
    result.size = p.parseSize
    hasSize = true
    if p.error.len > 0: return

  while p.tok.kind == tkParLe:
    if isSizeTag(p.tok.text):
      if hasSize: p.fail "a box has only one size"
      else: p.fail "the size has to come before the children"
      return
    if result.kind == nkCell:
      # The likely cause is a misspelled `rows` or `cols`, which by the rule
      # above became the name of a widget instead.
      p.fail "'" & result.name & "' names a widget, and a widget has no " &
             "children; did you mean (rows ...) or (cols ...)?"
      return
    result.children.add p.parseNode(isRoot = false)
    if p.error.len > 0: return

  if p.tok.kind != tkParRi:
    p.fail "expected ')' but found " & $p.tok
    return
  p.advance

proc parseLayout*(lex: var Lexer; tok: var Token): Layout =
  ## Parse the `(layout ...)` that `tok` starts, leaving `tok` on the token
  ## behind it. This is the entry point for a caller whose file holds more than
  ## a layout -- a `(config ...)` -- and who therefore owns the lexer.
  result = Layout(root: Node(kind: nkRows, name: "",
                             size: CellSize(kind: skStretch, value: 1),
                             children: @[]), error: "")
  var p = Parser(lex: lex, tok: tok, error: "")
  if p.tok.kind == tkError:
    p.fail p.tok.text
  elif p.tok.kind == tkEof:
    p.fail "nothing here; expected (layout ...)"
  else:
    if p.tok.kind == tkParLe and toTag(p.tok.text) != tagLayout:
      p.fail "expected (layout ...) but found (" & p.tok.text
    let root = p.parseNode(isRoot = true)
    if p.error.len == 0: result.root = root
  result.error = p.error
  lex = p.lex
  tok = p.tok

proc parseLayout*(s: string): Layout =
  ## Parse a whole string as a NIF layout. Never raises: check `result.error`.
  var lex = initLexer(s)
  var tok = next(lex)
  result = parseLayout(lex, tok)
  if result.error.len == 0 and tok.kind != tkEof:
    result.error = tok.position & ": unexpected " & $tok & " behind the layout"

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

proc fixedSize(sz: CellSize; lineHeight, padding: int): int =
  case sz.kind
  of skPixels: result = sz.value
  of skLines: result = sz.value * lineHeight + 2 * padding
  of skStretch: result = 0

proc place(n: Node; r: Rect; lineHeight, padding, gap: int;
           res: var Table[string, Rect]) =
  if n.kind == nkCell:
    res[n.name] = r
    return
  if n.children.len == 0: return

  let vertical = n.kind == nkRows
  let axis = if vertical: r.h else: r.w
  let gaps = gap * (n.children.len - 1)

  var sizes = newSeq[int](n.children.len)
  var fixed = 0
  var weights = 0
  var lastStretch = -1
  for i in 0 ..< n.children.len:
    let sz = n.children[i].size
    if sz.kind == skStretch:
      weights += sz.value
      lastStretch = i
    else:
      sizes[i] = fixedSize(sz, lineHeight, padding)
      fixed += sizes[i]

  let remaining = max(0, axis - fixed - gaps)
  if weights > 0:
    var handed = 0
    for i in 0 ..< n.children.len:
      if n.children[i].size.kind == skStretch:
        if i == lastStretch:
          # The last stretching child takes the division's remainder, so the
          # children fill their parent exactly instead of leaving a seam.
          sizes[i] = remaining - handed
        else:
          sizes[i] = remaining * n.children[i].size.value div weights
          handed += sizes[i]

  var pos = if vertical: r.y else: r.x
  for i in 0 ..< n.children.len:
    let sub = if vertical: Rect(x: r.x, y: pos, w: r.w, h: sizes[i])
              else: Rect(x: pos, y: r.y, w: sizes[i], h: r.h)
    place(n.children[i], sub, lineHeight, padding, gap, res)
    pos += sizes[i] + gap

proc resolve*(layout: Layout; screenW, screenH: int;
              lineHeight: int = 20; padding: int = 6;
              gap: int = 0): Table[string, Rect] =
  ## Resolve the layout into named Rects given the window's dimensions.
  ## `lineHeight` resolves `(lines N)` sizes, `padding` is added above and
  ## below such a text area, and `gap` inserts pixel gaps between adjacent
  ## boxes so that the background can show through as a border.
  ## A layout that did not parse resolves to nothing.
  result = initTable[string, Rect]()
  if layout.error.len > 0: return
  place(layout.root, Rect(x: 0, y: 0, w: screenW, h: screenH),
        lineHeight, padding, gap, result)

proc hasCell(n: Node; name: string): bool =
  if n.kind == nkCell:
    result = n.name == name
  else:
    result = false
    for i in 0 ..< n.children.len:
      if hasCell(n.children[i], name): return true

proc cell*(layout: Layout; name: string): bool =
  ## Check if a cell name exists in the layout.
  result = hasCell(layout.root, name)

proc hitTest*(cells: Table[string, Rect]; x, y: int): CellHit =
  ## Given screen coordinates, return which cell was hit and the
  ## position relative to that cell's origin.
  let p = point(x, y)
  for name, r in cells:
    if r.contains(p):
      return CellHit(name: name,
                     pos: GlobalPos(x: x - r.x, y: y - r.y))
