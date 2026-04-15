# Layout manager: markdown table → named Rects.
#
# The layout IS a markdown table:
#
#   | toolbar, 2 lines                                        |
#   | local, 250px, scroll | divider, 4px | remote, *, scroll |
#   | log, 5 lines, scroll                                    |
#   | status, 1 line                                          |
#
# Each row is a horizontal slice. | separators create columns.
# Sizing: Npx (fixed pixels), N lines (font-relative), N* (stretch).

import std/[strutils, tables]
import coords

type
  SizeKind = enum
    skPixels,     ## fixed pixel count
    skLines,      ## N * lineHeight
    skStretch     ## weighted share of remaining space

  CellSize = object
    kind: SizeKind
    value: int   ## pixels, line count, or stretch weight

  Cell = object
    name: string
    width: CellSize   ## horizontal size (for multi-column rows)
    height: CellSize  ## vertical size (row height)
    subcells: seq[Cell] ## vertical stack within this cell (if ; was used)

  Row = object
    cells: seq[Cell]
    height: CellSize   ## resolved from the cells (max or first)

  Layout* = object
    rows: seq[Row]

  CellHit* = object
    name*: string
    pos*: GlobalPos

proc parseSize(s: string): CellSize =
  ## Parse "250px", "2 lines", "1 line", "*", "2*"
  let s = s.strip()
  if s.endsWith("px"):
    let num = s[0 ..< s.len - 2].strip()
    result = CellSize(kind: skPixels, value: parseInt(num))
  elif s.endsWith("lines") or s.endsWith("line"):
    let num = s.split()[0].strip()
    result = CellSize(kind: skLines, value: parseInt(num))
  elif s.endsWith("*"):
    if s == "*":
      result = CellSize(kind: skStretch, value: 1)
    else:
      let num = s[0 ..< s.len - 1].strip()
      result = CellSize(kind: skStretch, value: parseInt(num))
  else:
    raise newException(ValueError, "unknown size '" & s &
      "', expected Npx, N lines, or N*")

proc parseSingleCell(s: string): Cell =
  ## Parse "name, 250px" or "name, 2 lines" or "name, *"
  ## With one size spec: used as both width and height (context decides).
  ## With two size specs: first is height, second is width.
  let parts = s.strip().split(",")
  if parts.len == 0:
    raise newException(ValueError, "empty cell")

  result.name = parts[0].strip()
  result.width = CellSize(kind: skStretch, value: 1)  # default
  result.height = CellSize(kind: skStretch, value: 1) # default

  if parts.len == 2:
    let sz = parseSize(parts[1].strip())
    result.width = sz
    result.height = sz
  elif parts.len >= 3:
    result.height = parseSize(parts[1].strip())
    result.width = parseSize(parts[2].strip())

proc parseCell(s: string): Cell =
  ## Parse a cell, possibly containing ";" for vertical stacking.
  if ";" in s:
    let subs = s.split(";")
    result = parseSingleCell(subs[0])
    for i in 0 ..< subs.len:
      result.subcells.add parseSingleCell(subs[i])
  else:
    result = parseSingleCell(s)

proc parseLayout*(s: string): Layout =
  ## Parse a markdown table string into a Layout.
  for rawLine in s.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    if not line.startsWith("|"): continue

    # Split by | and trim empty first/last
    var parts: seq[string]
    for p in line.split("|"):
      let trimmed = p.strip()
      if trimmed.len > 0:
        parts.add trimmed

    if parts.len == 0: continue

    var row: Row
    for p in parts:
      row.cells.add parseCell(p)

    # Row height: for single-column rows, the cell's size IS the row height.
    # For multi-column rows, the cell sizes are widths; the row stretches.
    if row.cells.len == 1:
      row.height = row.cells[0].height
    else:
      row.height = CellSize(kind: skStretch, value: 1)

    result.rows.add row

proc resolveSize(sz: CellSize; lineHeight, padding: int): int =
  case sz.kind
  of skPixels: sz.value
  of skLines: sz.value * lineHeight + 2 * padding
  of skStretch: 0  # resolved later

proc resolveSubcells(subcells: seq[Cell]; parent: Rect;
                     lineHeight, padding, gap: int;
                     result: var Table[string, Rect]) =
  ## Resolve vertically stacked subcells within a parent rect.
  let subGaps = gap * max(0, subcells.len - 1)
  var subHeights = newSeq[int](subcells.len)
  var totalFixed = 0
  var totalStretch = 0
  for i, sc in subcells:
    let h = resolveSize(sc.height, lineHeight, padding)
    if sc.height.kind == skStretch:
      totalStretch += sc.height.value
    else:
      totalFixed += h
    subHeights[i] = h
  let remain = max(0, parent.h - totalFixed - subGaps)
  if totalStretch > 0:
    for i, sc in subcells:
      if sc.height.kind == skStretch:
        subHeights[i] = (remain * sc.height.value) div totalStretch
  var sy = parent.y
  for i, sc in subcells:
    result[sc.name] = Rect(x: parent.x, y: sy, w: parent.w, h: subHeights[i])
    sy += subHeights[i] + gap

proc resolve*(layout: Layout; screenW, screenH: int;
              lineHeight: int = 20; padding: int = 6;
              gap: int = 0): Table[string, Rect] =
  ## Resolve the layout into named Rects given screen dimensions.
  ## lineHeight is used to resolve "N lines" sizes.
  ## padding is added above and below the text area for "N lines" cells.
  ## gap inserts pixel gaps between adjacent cells (for visible borders).
  result = initTable[string, Rect]()

  let rowGaps = gap * max(0, layout.rows.len - 1)

  # Pass 1: resolve row heights
  var rowHeights = newSeq[int](layout.rows.len)
  var totalFixed = 0
  var totalStretchWeight = 0

  for i, row in layout.rows:
    let h = resolveSize(row.height, lineHeight, padding)
    if row.height.kind == skStretch:
      totalStretchWeight += row.height.value
    else:
      totalFixed += h
    rowHeights[i] = h

  # Distribute remaining space to stretch rows
  let remaining = max(0, screenH - totalFixed - rowGaps)
  if totalStretchWeight > 0:
    for i, row in layout.rows:
      if row.height.kind == skStretch:
        rowHeights[i] = (remaining * row.height.value) div totalStretchWeight

  # Pass 2: resolve cell positions
  var y = 0
  for i, row in layout.rows:
    let rowH = rowHeights[i]
    let colGaps = gap * max(0, row.cells.len - 1)
    if row.cells.len == 1:
      let c = row.cells[0]
      let r = Rect(x: 0, y: y, w: screenW, h: rowH)
      if c.subcells.len > 0:
        resolveSubcells(c.subcells, r, lineHeight, padding, gap, result)
      else:
        result[c.name] = r
    else:
      # Multi-column: resolve widths
      var cellWidths = newSeq[int](row.cells.len)
      var fixedW = 0
      var stretchW = 0
      for j, c in row.cells:
        let w = resolveSize(c.width, lineHeight, padding)
        if c.width.kind == skStretch:
          stretchW += c.width.value
        else:
          fixedW += w
        cellWidths[j] = w

      let remainW = max(0, screenW - fixedW - colGaps)
      if stretchW > 0:
        for j, c in row.cells:
          if c.width.kind == skStretch:
            cellWidths[j] = (remainW * c.width.value) div stretchW

      var x = 0
      for j, c in row.cells:
        let r = Rect(x: x, y: y, w: cellWidths[j], h: rowH)
        if c.subcells.len > 0:
          resolveSubcells(c.subcells, r, lineHeight, padding, gap, result)
        else:
          result[c.name] = r
        x += cellWidths[j] + gap

    y += rowH + gap

proc cell*(layout: Layout; name: string): bool =
  ## Check if a cell name exists in the layout.
  for row in layout.rows:
    for c in row.cells:
      if c.name == name: return true
  return false

proc hitTest*(cells: Table[string, Rect]; x, y: int): CellHit =
  ## Given screen coordinates, return which cell was hit and the
  ## position relative to that cell's origin.
  let p = point(x, y)
  for name, r in cells:
    if r.contains(p):
      return CellHit(name: name,
                     pos: GlobalPos(x: x - r.x, y: y - r.y))
