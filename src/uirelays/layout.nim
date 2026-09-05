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
#   (px 250)     250 *logical* pixels: `resolve`'s `uiScale` turns them into
#                the display's, so one layout describes the same window on a
#                4K laptop panel as on a 96 dpi monitor
#   (lines 5)    5 * lineHeight, plus the padding above and below
#   (stretch 2)  two shares of what the fixed sizes leave over
#
# Leaving the size out means `(stretch 1)`.

import std/[tables, math]
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

  LayoutMetrics* = object
    ## What a layout needs besides itself to become rects: the window it fills
    ## and the numbers its sizes are counted in. One value, passed to
    ## `resolve`, `splitterAt` and `dragTo` alike, so that the three of them
    ## cannot end up talking about different windows -- a border found with
    ## one set of numbers and moved with another would move somewhere else.
    screenW*, screenH*: int
    lineHeight*: int   ## what `(lines N)` counts in
    padding*: int      ## added above and below a `(lines N)` box
    gap*: int          ## pixels between adjacent boxes: the border the
                       ## background shows through, and the grip a splitter is
                       ## caught by
    uiScale*: int      ## percent; enlarges the `(px N)` sizes

  BoxPath* = seq[int]
    ## Which box, said in child indices from the root: `@[0, 1]` is the second
    ## child of the first. A name would not do -- the boxes that get dragged
    ## about are the `rows` and `cols` between the named ones, and those have
    ## nothing to be called.

  Splitter* = object
    ## The border between two boxes, and enough to move it again later.
    found*: bool       ## false for "the pointer is not on one"
    parent*: BoxPath   ## the container whose children it lies between
    before*: int       ## the child on the left of it, or above it
    vertical*: bool    ## a `rows` border: it lies across and moves up and down
    grab*: int         ## how far into the border the pointer took hold of it.
                       ## Kept so that a drag moves the border *by* what the
                       ## pointer moved: a grip is several pixels wide, and one
                       ## that snapped its edge to the pointer would jump by up
                       ## to that much the moment it was touched.

const MinBox = 12
  ## Logical pixels a box may not be dragged below. Zero would be a box that
  ## is not there, with nothing left to catch hold of -- and a panel that can
  ## only be brought back by typing is not what a drag is for.

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
    names: seq[string]  ## the cells named so far, to catch a second one of
                        ## the same name; see `parseNode`

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
    # A name is the whole of how a cell is asked for afterwards -- `resolve`
    # hands out one rect per name -- so a second box of the same name is not
    # two boxes but one rect quietly standing in for both, the later one
    # winning. Said here, where the line number is still known.
    for other in p.names:
      if other == result.name:
        p.fail "two cells are called '" & result.name & "'"
        return
    p.names.add result.name
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

proc fixedSize(sz: CellSize; lineHeight, padding, uiScale: int): int =
  case sz.kind
  of skPixels: result = sz.value * uiScale div 100
  of skLines: result = sz.value * lineHeight + 2 * padding
  of skStretch: result = 0

proc childRects(n: Node; r: Rect; m: LayoutMetrics): seq[Rect] =
  ## Where each child of `n` lands inside `r`. The division is done here and
  ## nowhere else: `place` walks these to name them, and everything that has
  ## to know where the border between two boxes *is* asks the same question of
  ## the same arithmetic.
  result = @[]
  if n.kind == nkCell or n.children.len == 0: return

  let vertical = n.kind == nkRows
  let axis = if vertical: r.h else: r.w
  let gaps = m.gap * (n.children.len - 1)

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
      sizes[i] = fixedSize(sz, m.lineHeight, m.padding, m.uiScale)
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

  result = newSeq[Rect](n.children.len)
  var pos = if vertical: r.y else: r.x
  for i in 0 ..< n.children.len:
    result[i] = if vertical: Rect(x: r.x, y: pos, w: r.w, h: sizes[i])
                else: Rect(x: pos, y: r.y, w: sizes[i], h: r.h)
    pos += sizes[i] + m.gap

proc place(n: Node; r: Rect; m: LayoutMetrics; res: var Table[string, Rect]) =
  if n.kind == nkCell:
    res[n.name] = r
    return
  let rects = childRects(n, r, m)
  for i in 0 ..< n.children.len:
    place(n.children[i], rects[i], m, res)

proc resolve*(layout: Layout; m: LayoutMetrics): Table[string, Rect] =
  ## Resolve the layout into named Rects. A layout that did not parse resolves
  ## to nothing.
  result = initTable[string, Rect]()
  if layout.error.len > 0: return
  place(layout.root, Rect(x: 0, y: 0, w: m.screenW, h: m.screenH), m, result)

proc resolve*(layout: Layout; screenW, screenH: int;
              lineHeight: int = 20; padding: int = 6;
              gap: int = 0; uiScale: int = 100): Table[string, Rect] =
  ## Resolve the layout into named Rects given the window's dimensions.
  ## `lineHeight` resolves `(lines N)` sizes, `padding` is added above and
  ## below such a text area, and `gap` inserts pixel gaps between adjacent
  ## boxes so that the background can show through as a border.
  ##
  ## `uiScale` is `ScreenLayout.uiScale`, and enlarges the `(px N)` sizes in
  ## the layout text -- the only sizes here a caller cannot scale on its own.
  ## Everything passed in above is in the driver's own unit already, so a
  ## caller that scales its font has to scale `padding` and `gap` with it.
  ##
  ## A layout that did not parse resolves to nothing.
  result = layout.resolve(LayoutMetrics(screenW: screenW, screenH: screenH,
                                        lineHeight: lineHeight,
                                        padding: padding, gap: gap,
                                        uiScale: uiScale))

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

# ---------------------------------------------------------------------------
# Splitters. The gaps between the boxes are already there -- they are what the
# background shows through, and what a focus frame is drawn in -- so they are
# what a pointer grabs to move a border. Nothing new is drawn and no box gives
# up a pixel to a handle.
#
# What moves is never a *cell*: a cell has no say in its own size, the box it
# sits in does. So a splitter names the container and the child before the
# border, and the two children on either side settle the space between them.
# ---------------------------------------------------------------------------

proc findSplitter(n: Node; r: Rect; path: BoxPath; m: LayoutMetrics;
                  x, y, slack: int): Splitter =
  result = Splitter(found: false, parent: @[], before: 0, vertical: false,
                    grab: 0)
  if n.kind == nkCell or n.children.len == 0: return
  let rects = childRects(n, r, m)
  let vertical = n.kind == nkRows
  let p = point(x, y)
  for i in 0 ..< n.children.len - 1:
    let a = rects[i]
    let b = rects[i + 1]
    # The gap, widened by `slack` on either side: a layout resolved with no
    # gap at all still has borders, and one of four pixels is a small target
    # for a pointer that is being moved rather than aimed.
    let strip =
      if vertical:
        Rect(x: r.x, y: a.y + a.h - slack, w: r.w,
             h: max(0, b.y - (a.y + a.h)) + 2 * slack)
      else:
        Rect(x: a.x + a.w - slack, y: r.y,
             w: max(0, b.x - (a.x + a.w)) + 2 * slack, h: r.h)
    if strip.contains(p):
      let edge = if vertical: a.y + a.h else: a.x + a.w
      return Splitter(found: true, parent: path, before: i,
                      vertical: vertical,
                      grab: (if vertical: y else: x) - edge)
  # Not one of this box's own borders, so it belongs to whatever is inside the
  # child under the pointer. Outer borders win the ties this leaves at a
  # T-junction, which is the answer that needs no explaining: it is the border
  # that runs *through* the junction rather than the one that stops at it.
  for i in 0 ..< n.children.len:
    if rects[i].contains(p):
      return findSplitter(n.children[i], rects[i], path & i, m, x, y, slack)

proc splitterAt*(layout: Layout; m: LayoutMetrics; x, y: int;
                 slack = 2): Splitter =
  ## The border the pointer is on, or one whose `found` is false. `slack` is
  ## in logical pixels, like everything else a caller states.
  if layout.error.len > 0:
    return Splitter(found: false, parent: @[], before: 0, vertical: false,
                    grab: 0)
  findSplitter(layout.root, Rect(x: 0, y: 0, w: m.screenW, h: m.screenH), @[],
               m, x, y, max(0, slack * m.uiScale div 100))

proc descend(n: Node; r: Rect; path: BoxPath; step: int; m: LayoutMetrics;
             box: var Rect; rects: var seq[Rect]): bool =
  ## Follow `path` down to the container it names, handing back that box and
  ## where its children are inside it.
  if step >= path.len:
    if n.kind == nkCell or n.children.len == 0: return false
    box = r
    rects = childRects(n, r, m)
    return true
  let cr = childRects(n, r, m)
  if path[step] < 0 or path[step] >= cr.len: return false
  descend(n.children[path[step]], cr[path[step]], path, step + 1, m, box, rects)

proc splitterRect*(layout: Layout; m: LayoutMetrics; s: Splitter): Rect =
  ## The gap `s` lies in -- what to paint to show that it can be taken hold
  ## of. Empty when the splitter is not one.
  result = Rect(x: 0, y: 0, w: 0, h: 0)
  if not s.found or layout.error.len > 0: return
  var box = Rect(x: 0, y: 0, w: 0, h: 0)
  var rects: seq[Rect] = @[]
  if not descend(layout.root, Rect(x: 0, y: 0, w: m.screenW, h: m.screenH),
                 s.parent, 0, m, box, rects): return
  if s.before < 0 or s.before + 1 >= rects.len: return
  let a = rects[s.before]
  let b = rects[s.before + 1]
  result =
    if s.vertical:
      Rect(x: box.x, y: a.y + a.h, w: box.w, h: max(0, b.y - (a.y + a.h)))
    else:
      Rect(x: a.x + a.w, y: box.y, w: max(0, b.x - (a.x + a.w)), h: box.h)

proc snapped(sz: CellSize; px: int; m: LayoutMetrics; down = false): int =
  ## The size nearest `px` that `sz`'s unit can say -- or the nearest one at or
  ## below it, which is what the box that takes what is *left* has to do: a
  ## neighbour that rounded up would push the pair wider than the room the two
  ## of them have.
  ##
  ## A box counted in lines can only be a whole number of them, so a drag on
  ## such a border moves in steps and lands where the text does.
  case sz.kind
  of skLines:
    let half = if down: 0 else: m.lineHeight div 2
    let lines = max(0, (px - 2 * m.padding + half) div m.lineHeight)
    result = lines * m.lineHeight + 2 * m.padding
  of skPixels, skStretch: result = px

proc dragChild(n: var Node; r: Rect; path: BoxPath; step: int;
               before, to: int; m: LayoutMetrics): bool =
  if step < path.len:
    let cr = childRects(n, r, m)
    if path[step] < 0 or path[step] >= cr.len: return false
    return dragChild(n.children[path[step]], cr[path[step]], path, step + 1,
                     before, to, m)
  if n.kind == nkCell or before < 0 or before + 1 >= n.children.len:
    return false
  let rects = childRects(n, r, m)
  let vertical = n.kind == nkRows
  var px = newSeq[int](n.children.len)
  for i in 0 ..< px.len:
    px[i] = if vertical: rects[i].h else: rects[i].w
  let was = px
  let start = if vertical: rects[before].y else: rects[before].x
  # The two boxes share what the two of them have. Everything else in this
  # container stays the size it is: a drag moves one border, not the window.
  let pair = px[before] + m.gap + px[before + 1]
  let minBox = max(1, MinBox * m.uiScale div 100)
  if pair - m.gap < 2 * minBox: return false
  var want = clamp(to - start, minBox, pair - m.gap - minBox)
  want = clamp(snapped(n.children[before].size, want, m), minBox,
               pair - m.gap - minBox)
  var rest = clamp(snapped(n.children[before + 1].size, pair - m.gap - want, m,
                           down = true), minBox, pair - m.gap - minBox)
  # Whatever the neighbour's unit could not express goes back to the box being
  # dragged, when its own unit can hold it -- so a pair of boxes still fills
  # the room the two of them had. Two boxes both counted in lines are the one
  # case where a few pixels have nowhere to go, and there the background shows
  # through them, which is what it is there for.
  if n.children[before].size.kind != skLines:
    want = clamp(pair - m.gap - rest, minBox, pair - m.gap - minBox)
  px[before] = want
  px[before + 1] = rest
  if px == was: return false

  for j in [before, before + 1]:
    case n.children[j].size.kind
    of skPixels:
      n.children[j].size.value = max(0, px[j] * 100 div m.uiScale)
    of skLines:
      n.children[j].size.value = max(0, (px[j] - 2 * m.padding +
                                         m.lineHeight div 2) div m.lineHeight)
    of skStretch: discard   # below, with the rest of its group
  # A stretching box has no size of its own, only a share of what is left, so
  # one of them cannot be set without saying what the others get. They are
  # rewritten together, out of the pixels they have now: that is what keeps a
  # drag at one border from moving every other stretching box in the container
  # -- their weights go on describing the window they are already in.
  var totalPx = 0
  var stretching = 0
  for i in 0 ..< n.children.len:
    if n.children[i].size.kind == skStretch:
      totalPx += px[i]
      inc stretching
  # One of them is the exception: it takes everything the others leave, and
  # says so by having no number worth writing. Rewriting it would turn a
  # `(editor)` into a `(editor (stretch 1000))` and say nothing more.
  # Only when one of the two that moved is a stretching box. When neither is,
  # the pair still adds up to what it did, so every other box in the container
  # has the pixels it had -- and rewriting weights that already say so would
  # churn the text of a file for nothing.
  let stretchMoved = n.children[before].size.kind == skStretch or
                     n.children[before + 1].size.kind == skStretch
  if stretchMoved and stretching > 1 and totalPx > 0:
    # The weights *are* the pixels, reduced by what they have in common. A
    # share of the leftover space is a ratio, so any factor of them would do --
    # but this one divides back into exactly the pixels it came from, and a
    # scale of its own (per mille, say) would not: the rounding would take a
    # pixel off a box at the far end of the container that nobody dragged.
    var common = 0
    for i in 0 ..< n.children.len:
      if n.children[i].size.kind == skStretch: common = gcd(common, px[i])
    if common < 1: common = 1
    for i in 0 ..< n.children.len:
      if n.children[i].size.kind == skStretch:
        n.children[i].size.value = max(1, px[i] div common)
  result = true

proc dragTo*(layout: var Layout; m: LayoutMetrics; s: Splitter;
             x, y: int): bool =
  ## Move the border `s` to the pointer, and say whether that changed
  ## anything. The sizes are written back in the unit each box was already
  ## written in, so a layout keeps its shape as text: a box in `(px N)` stays
  ## in pixels, one in `(lines N)` stays in whole lines, and stretching ones
  ## keep sharing what is left over.
  if not s.found or layout.error.len > 0: return false
  dragChild(layout.root, Rect(x: 0, y: 0, w: m.screenW, h: m.screenH),
            s.parent, 0, s.before, (if s.vertical: y else: x) - s.grab, m)

# ---------------------------------------------------------------------------
# Growing and shrinking. A window whose panels can be split and closed is a
# window whose *layout* gains and loses boxes, and since the layout is text in
# a file, that is all a split is: the tree grows a leaf and gets written out
# again. Nothing else has to remember that the panel is there.
# ---------------------------------------------------------------------------

proc collectNames(n: Node; res: var seq[string]) =
  if n.kind == nkCell: res.add n.name
  else:
    for i in 0 ..< n.children.len: collectNames(n.children[i], res)

proc cellNames*(layout: Layout): seq[string] =
  ## Every cell in the layout, in the order it is written. An application that
  ## makes a widget per cell builds its list from this.
  result = @[]
  if layout.error.len == 0: collectNames(layout.root, result)

proc findCell(n: Node; name: string; path: var BoxPath): bool =
  ## The path to the cell called `name`, or false. Names are unique -- the
  ## parser sees to that -- so the first one found is the only one.
  if n.kind == nkCell: return n.name == name
  for i in 0 ..< n.children.len:
    path.add i
    if findCell(n.children[i], name, path): return true
    path.setLen path.len - 1
  result = false

proc reduceWeights(n: var Node) =
  ## Stretch weights count only against each other, so they may be divided by
  ## what they have in common -- which is what keeps them from doubling their
  ## way up to unreadable numbers over a session of splitting.
  var common = 0
  for i in 0 ..< n.children.len:
    if n.children[i].size.kind == skStretch:
      common = gcd(common, n.children[i].size.value)
  if common > 1:
    for i in 0 ..< n.children.len:
      if n.children[i].size.kind == skStretch:
        n.children[i].size.value = max(1, n.children[i].size.value div common)

proc splitChild(n: var Node; i: int; newName: string; wanted: NodeKind) =
  var fresh = Node(kind: nkCell, name: newName,
                   size: CellSize(kind: skStretch, value: 1), children: @[])
  if n.kind == wanted:
    # The parent already divides the way the split wants, so the new box goes
    # in beside the old one instead of into a container of its own: a tree
    # that nests only where it has to is a file somebody can still read.
    case n.children[i].size.kind
    of skPixels, skLines:
      # Whole units both, and an odd one goes to the newcomer.
      let whole = n.children[i].size.value
      fresh.size = CellSize(kind: n.children[i].size.kind,
                            value: whole - whole div 2)
      n.children[i].size.value = whole div 2
    of skStretch:
      # Doubling everybody else halves this box and moves no other border:
      # a weight says nothing on its own, only what it is against the rest.
      let w = n.children[i].size.value
      for j in 0 ..< n.children.len:
        if j != i and n.children[j].size.kind == skStretch:
          n.children[j].size.value = n.children[j].size.value * 2
      fresh.size = CellSize(kind: skStretch, value: w)
    n.children.insert(fresh, i + 1)
    reduceWeights(n)
  else:
    # The parent divides the other way, so the two of them need a container,
    # and it takes the size the cell had: what the split divides is the room
    # the one box was already given.
    var inner = n.children[i]
    let outer = inner.size
    inner.size = CellSize(kind: skStretch, value: 1)
    n.children[i] = Node(kind: wanted, name: "", size: outer,
                         children: @[inner, fresh])

proc splitAt(n: var Node; path: BoxPath; step: int; newName: string;
             wanted: NodeKind) =
  if step < path.len - 1:
    splitAt(n.children[path[step]], path, step + 1, newName, wanted)
  else:
    splitChild(n, path[step], newName, wanted)

proc splitCell*(layout: var Layout; name, newName: string;
                asColumn: bool): bool =
  ## Put a second box called `newName` beside the one called `name`: to its
  ## right when `asColumn`, below it otherwise. The room comes out of `name`
  ## alone -- halved in whatever unit it was written in -- so nothing else in
  ## the window moves.
  ##
  ## False, and nothing changed, if `name` is not there, if `newName` already
  ## is, or if the layout did not parse.
  if layout.error.len > 0 or newName.len == 0: return false
  if hasCell(layout.root, newName) or not hasCell(layout.root, name):
    return false
  var path: BoxPath = @[]
  discard findCell(layout.root, name, path)
  splitAt(layout.root, path, 0, newName, if asColumn: nkCols else: nkRows)
  result = true

proc removeAt(n: var Node; path: BoxPath; step: int) =
  if step < path.len - 1:
    removeAt(n.children[path[step]], path, step + 1)
    # On the way back out: a container left holding one child has nothing to
    # divide any more, so it stands aside and the survivor takes its place --
    # and its size, which is the room the pair had between them.
    let i = path[step]
    if n.children[i].kind != nkCell and n.children[i].children.len == 1:
      var survivor = n.children[i].children[0]
      survivor.size = n.children[i].size
      n.children[i] = survivor
  else:
    n.children.delete path[step]

proc removeCell*(layout: var Layout; name: string): bool =
  ## Take the box called `name` out of the layout. False, and nothing changed,
  ## if it is not there or if it is the only box left: a window with nothing
  ## in it has nowhere to type the layout back.
  if layout.error.len > 0: return false
  var path: BoxPath = @[]
  if not findCell(layout.root, name, path): return false
  if path.len == 1 and layout.root.children.len == 1: return false
  removeAt(layout.root, path, 0)
  result = true

# ---------------------------------------------------------------------------
# Writing one back. A layout that can be dragged has to be storable, and the
# file it is stored in is the one somebody types in -- so what comes out here
# is what a person would have written, and `parseLayout` reads it back as the
# same tree.
# ---------------------------------------------------------------------------

proc sizeText(sz: CellSize): string =
  ## What a box says about its own size, or nothing at all: `(stretch 1)` is
  ## what leaving it out means, so leaving it out is how it is written.
  case sz.kind
  of skPixels: " (px " & $sz.value & ")"
  of skLines: " (lines " & $sz.value & ")"
  of skStretch:
    if sz.value == 1: "" else: " (stretch " & $sz.value & ")"

proc nodeText(n: Node; indent: int; tag: string): string =
  var ind = ""
  for _ in 0 ..< indent: ind.add ' '
  if n.kind == nkCell:
    result = ind & "(" & n.name & sizeText(n.size) & ")"
  else:
    result = ind & "(" & tag & sizeText(n.size)
    for c in n.children:
      result.add "\n"
      result.add nodeText(c, indent + 2,
                          if c.kind == nkRows: "rows"
                          elif c.kind == nkCols: "cols" else: "")
    result.add ")"

proc `$`*(layout: Layout): string =
  ## The layout as the file it came from: one `(layout ...)`, two spaces per
  ## level, and a trailing newline. A layout that did not parse writes nothing
  ## -- there is nothing of it to write.
  if layout.error.len > 0: return ""
  result = nodeText(layout.root, 0, "layout") & "\n"
