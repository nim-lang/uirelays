## todo.nim -- Simple Todo list app using uirelays/layout.
## Add tasks, toggle completion, delete items, and navigate by keyboard.
##
## Compile from the examples/ directory:
##   nim c --path:../src -d:sdl3 -o:todo-highdpi todo.nim

import uirelays
import uirelays/layout
import std/[strutils, tables, unicode]

const
  BaseFontSize = 15

  LayoutSpec = """
  | header, 2 lines |
  | composer, 2 lines |
  | list, * |
  | status, 1 line |
"""

  bgColor          = color(244, 243, 241)
  panelColor       = color(255, 255, 255)
  panelAltColor    = color(247, 248, 249)
  borderColor      = color(216, 219, 223)
  textColor        = color(29, 31, 34)
  mutedTextColor   = color(103, 107, 112)
  accentColor      = color(44, 120, 220)
  selectedRowColor = color(233, 240, 250)
  successColor     = color(46, 160, 67)
  dangerColor      = color(208, 56, 76)
  placeholderColor = color(126, 130, 135)
  dividerColor     = color(229, 232, 235)

type
  TodoItem = object
    text: string
    done: bool

  Focus = enum
    ComposerFocus, ListFocus

  HoverKind = enum
    HoverNone, HoverComposer, HoverRow, HoverCheckbox, HoverDelete

  HoverTarget = object
    kind: HoverKind
    index: int

proc insetRect(r: Rect; pad: int): Rect =
  rect(r.x + pad, r.y + pad, max(0, r.w - pad * 2), max(0, r.h - pad * 2))

proc drawBorder(r: Rect; c: Color) =
  if r.w <= 0 or r.h <= 0:
    return
  drawLine(r.x, r.y, r.x + r.w - 1, r.y, c)
  drawLine(r.x, r.y, r.x, r.y + r.h - 1, c)
  drawLine(r.x + r.w - 1, r.y, r.x + r.w - 1, r.y + r.h - 1, c)
  drawLine(r.x, r.y + r.h - 1, r.x + r.w - 1, r.y + r.h - 1, c)

proc countDone(items: seq[TodoItem]): int =
  result = 0
  for item in items:
    if item.done:
      inc result

proc summaryText(total, done: int): string =
  let remaining = total - done
  if total == 0:
    return "No tasks"
  if done == 0:
    return $remaining & " remaining"
  if remaining == 0:
    return "All completed"
  $remaining & " remaining, " & $done & " completed"

proc eventText(text: array[4, char]): string =
  result = ""
  for ch in text:
    if ch == '\0':
      break
    result.add ch

proc removeLastRune(s: var string) =
  if s.len == 0:
    return
  let (_, runeBytes) = lastRune(s, s.high)
  s.setLen(s.len - runeBytes)

proc truncateText(font: Font; text: string; maxWidth: int): string =
  if maxWidth <= 0:
    return ""
  if measureText(font, text).w <= maxWidth:
    return text

  let ellipsis = "..."
  let ellipsisWidth = measureText(font, ellipsis).w
  if ellipsisWidth > maxWidth:
    return ""

  let runes = text.toRunes
  var prefixes = newSeq[string](runes.len + 1)
  for i, rune in runes:
    prefixes[i + 1] = prefixes[i] & $rune

  var low = 0
  var high = runes.len
  while low < high:
    let mid = (low + high + 1) shr 1
    if measureText(font, prefixes[mid] & ellipsis).w <= maxWidth:
      low = mid
    else:
      high = mid - 1

  if low == 0:
    return ellipsis
  result = prefixes[low]
  result.add ellipsis

proc rowHeightFor(fm: FontMetrics): int =
  fm.lineHeight + 8

proc visibleRowsFor(listInner: Rect; rowHeight: int): int =
  max(1, listInner.h div rowHeight)

proc checkboxRect(rowRect: Rect): Rect =
  let size = min(16, max(10, rowRect.h - 8))
  rect(rowRect.x + 8, rowRect.y + (rowRect.h - size) div 2, size, size)

proc deleteRect(rowRect: Rect): Rect =
  let size = min(18, max(12, rowRect.h - 8))
  rect(rowRect.x + rowRect.w - 8 - size, rowRect.y + (rowRect.h - size) div 2, size, size)

proc rowRectFor(listInner: Rect; rowHeight, visibleIndex: int): Rect =
  rect(listInner.x, listInner.y + visibleIndex * rowHeight, listInner.w, rowHeight)

proc clampSelection(items: seq[TodoItem]; selectedIndex, scrollIndex: var int;
                    visibleRows: int) =
  if items.len == 0:
    selectedIndex = -1
    scrollIndex = 0
    return

  selectedIndex = clamp(selectedIndex, 0, items.len - 1)
  let maxScroll = max(0, items.len - visibleRows)
  scrollIndex = clamp(scrollIndex, 0, maxScroll)

  if selectedIndex < scrollIndex:
    scrollIndex = selectedIndex
  elif selectedIndex >= scrollIndex + visibleRows:
    scrollIndex = selectedIndex - visibleRows + 1

  scrollIndex = clamp(scrollIndex, 0, maxScroll)

proc listInnerRect(listRect: Rect): Rect =
  insetRect(listRect, 6)

proc composerInnerRect(composerRect: Rect): Rect =
  insetRect(composerRect, 8)

proc hitList(listInner: Rect; rowHeight, scrollIndex: int; items: seq[TodoItem];
             x, y: int): HoverTarget =
  if not listInner.contains(point(x, y)):
    return HoverTarget(kind: HoverNone, index: -1)

  let visibleIndex = (y - listInner.y) div rowHeight
  let itemIndex = scrollIndex + visibleIndex
  if itemIndex < 0 or itemIndex >= items.len:
    return HoverTarget(kind: HoverNone, index: -1)

  let rowRect = rowRectFor(listInner, rowHeight, visibleIndex)
  let p = point(x, y)
  if deleteRect(rowRect).contains(p):
    return HoverTarget(kind: HoverDelete, index: itemIndex)
  if checkboxRect(rowRect).contains(p):
    return HoverTarget(kind: HoverCheckbox, index: itemIndex)
  HoverTarget(kind: HoverRow, index: itemIndex)

proc drawCheckbox(r: Rect; checked: bool) =
  fillRect(r, if checked: successColor else: panelColor)
  drawBorder(r, if checked: successColor else: borderColor)
  if checked:
    drawLine(r.x + 4, r.y + r.h div 2, r.x + r.w div 2 - 1, r.y + r.h - 5, panelColor)
    drawLine(r.x + r.w div 2 - 1, r.y + r.h - 5, r.x + r.w - 4, r.y + 4, panelColor)

proc drawDeleteButton(r: Rect; hovered: bool) =
  let fg = if hovered: panelColor else: dangerColor
  let bg = if hovered: dangerColor else: panelColor
  fillRect(r, bg)
  drawBorder(r, dangerColor)
  let pad = 4
  drawLine(r.x + pad, r.y + pad, r.x + r.w - pad - 1, r.y + r.h - pad - 1, fg)
  drawLine(r.x + r.w - pad - 1, r.y + pad, r.x + pad, r.y + r.h - pad - 1, fg)

proc main =
  let win = createWindow(760, 560)
  var width = win.width
  var height = win.height

  var fm = FontMetrics()
  let font = openFont("", BaseFontSize, fm)
  setWindowTitle("Tasks")

  let parsedLayout = parseLayout(LayoutSpec)

  var items = @[
    TodoItem(text: "Review this week's priorities", done: true),
    TodoItem(text: "Reply to client email", done: false),
    TodoItem(text: "Prepare tomorrow's notes", done: false)
  ]
  var inputText = ""
  var focus = ComposerFocus
  var selectedIndex = if items.len > 0: 0 else: -1
  var scrollIndex = 0
  var mouseX = 0
  var mouseY = 0
  var running = true

  while running:
    var cells = parsedLayout.resolve(width, height, fm.lineHeight)
    let composerRect = composerInnerRect(cells["composer"])
    let listInner = listInnerRect(cells["list"])
    let rowHeight = rowHeightFor(fm)
    let visibleRows = visibleRowsFor(listInner, rowHeight)
    clampSelection(items, selectedIndex, scrollIndex, visibleRows)

    let inputFlags = if focus == ComposerFocus: {WantTextInput} else: {}
    var e = default Event
    while pollEvent(e, inputFlags):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowResizeEvent:
        width = e.x
        height = e.y
      of MouseMoveEvent:
        mouseX = e.x
        mouseY = e.y
      of MouseWheelEvent:
        if listInner.contains(point(mouseX, mouseY)):
          let maxScroll = max(0, items.len - visibleRows)
          scrollIndex = clamp(scrollIndex - e.y, 0, maxScroll)
      of MouseDownEvent:
        mouseX = e.x
        mouseY = e.y
        let p = point(e.x, e.y)
        if composerRect.contains(p):
          focus = ComposerFocus
        else:
          let hover = hitList(listInner, rowHeight, scrollIndex, items, e.x, e.y)
          case hover.kind
          of HoverDelete:
            focus = ListFocus
            if hover.index >= 0 and hover.index < items.len:
              items.delete(hover.index)
              clampSelection(items, selectedIndex, scrollIndex, visibleRows)
          of HoverCheckbox:
            focus = ListFocus
            if hover.index >= 0 and hover.index < items.len:
              selectedIndex = hover.index
              items[hover.index].done = not items[hover.index].done
              clampSelection(items, selectedIndex, scrollIndex, visibleRows)
          of HoverRow:
            focus = ListFocus
            selectedIndex = hover.index
            clampSelection(items, selectedIndex, scrollIndex, visibleRows)
          else:
            discard
      of TextInputEvent:
        if focus == ComposerFocus:
          let entered = eventText(e.text)
          if entered.len > 0:
            inputText.add entered
      of KeyDownEvent:
        case e.key
        of KeyEsc:
          running = false
        of KeyQ:
          if CtrlPressed in e.mods:
            running = false
        of KeyTab:
          if focus == ComposerFocus:
            focus = ListFocus
            if selectedIndex < 0 and items.len > 0:
              selectedIndex = 0
          else:
            focus = ComposerFocus
        of KeyEnter:
          if focus == ComposerFocus:
            let trimmed = strutils.strip(inputText)
            if trimmed.len > 0:
              items.add TodoItem(text: trimmed, done: false)
              inputText.setLen(0)
              selectedIndex = items.high
              clampSelection(items, selectedIndex, scrollIndex, visibleRows)
          elif selectedIndex >= 0 and selectedIndex < items.len:
            items[selectedIndex].done = not items[selectedIndex].done
        of KeySpace:
          if focus == ListFocus and selectedIndex >= 0 and selectedIndex < items.len:
            items[selectedIndex].done = not items[selectedIndex].done
        of KeyBackspace:
          if focus == ComposerFocus:
            removeLastRune(inputText)
          elif focus == ListFocus and selectedIndex >= 0 and selectedIndex < items.len:
            items.delete(selectedIndex)
            clampSelection(items, selectedIndex, scrollIndex, visibleRows)
        of KeyDelete:
          if focus == ListFocus and selectedIndex >= 0 and selectedIndex < items.len:
            items.delete(selectedIndex)
            clampSelection(items, selectedIndex, scrollIndex, visibleRows)
        of KeyUp:
          if focus == ListFocus and items.len > 0:
            if selectedIndex < 0: selectedIndex = 0 else: dec selectedIndex
            clampSelection(items, selectedIndex, scrollIndex, visibleRows)
        of KeyDown:
          if focus == ListFocus and items.len > 0:
            if selectedIndex < 0: selectedIndex = 0 else: inc selectedIndex
            clampSelection(items, selectedIndex, scrollIndex, visibleRows)
        else:
          if focus == ComposerFocus:
            if e.key == KeyV and CtrlPressed in e.mods:
              inputText.add getClipboardText()
      else:
        discard

    cells = parsedLayout.resolve(width, height, fm.lineHeight)
    let headerRect = cells["header"]
    let composerCell = cells["composer"]
    let listRect = cells["list"]
    let statusRect = cells["status"]
    let composerBox = composerInnerRect(composerCell)
    let listClip = listInnerRect(listRect)
    let listVisibleRows = visibleRowsFor(listClip, rowHeight)
    clampSelection(items, selectedIndex, scrollIndex, listVisibleRows)

    let hover = if composerBox.contains(point(mouseX, mouseY)):
                  HoverTarget(kind: HoverComposer, index: -1)
                else:
                  hitList(listClip, rowHeight, scrollIndex, items, mouseX, mouseY)

    case hover.kind
    of HoverComposer:
      setCursor(curIbeam)
    of HoverRow, HoverCheckbox, HoverDelete:
      setCursor(curHand)
    else:
      setCursor(curArrow)

    let doneCount = countDone(items)
    let openCount = items.len - doneCount

    fillRect(rect(0, 0, width, height), bgColor)
    fillRect(headerRect, panelColor)
    discard drawText(font, headerRect.x + 14, headerRect.y + 10,
      "Tasks", textColor, panelColor)
    discard drawText(font, headerRect.x + 14, headerRect.y + 28,
      summaryText(items.len, doneCount), mutedTextColor, panelColor)
    drawLine(headerRect.x + 14, headerRect.y + headerRect.h - 1,
      headerRect.x + headerRect.w - 14, headerRect.y + headerRect.h - 1, dividerColor)

    fillRect(composerCell, panelColor)
    let composerBg = if focus == ComposerFocus: panelColor else: panelAltColor
    fillRect(composerBox, composerBg)
    drawBorder(composerBox, if focus == ComposerFocus: accentColor else: borderColor)

    let composerTextX = composerBox.x + 10
    let composerTextY = composerBox.y + (composerBox.h - fm.lineHeight) div 2
    if inputText.len == 0:
      discard drawText(font, composerTextX, composerTextY,
        "Add a task", placeholderColor, composerBg)
    else:
      let shown = truncateText(font, inputText, composerBox.w - 20)
      discard drawText(font, composerTextX, composerTextY,
        shown, textColor, composerBg)

    if focus == ComposerFocus:
      let caretText = truncateText(font, inputText, composerBox.w - 20)
      let caretX = composerTextX + measureText(font, caretText).w + 1
      if (getTicks() div 500) mod 2 == 0:
        drawLine(caretX, composerBox.y + 7, caretX, composerBox.y + composerBox.h - 8, accentColor)

    fillRect(listRect, panelColor)
    drawLine(listRect.x + 14, listRect.y, listRect.x + listRect.w - 14, listRect.y, dividerColor)

    saveState()
    setClipRect(listClip)
    if items.len == 0:
      discard drawText(font, listClip.x + 10, listClip.y + 10,
        "Nothing to do.", placeholderColor, panelColor)
    else:
      for visibleIndex in 0 ..< listVisibleRows:
        let itemIndex = scrollIndex + visibleIndex
        if itemIndex >= items.len:
          break

        let rowRect = rowRectFor(listClip, rowHeight, visibleIndex)
        let rowBg =
          if itemIndex == selectedIndex: selectedRowColor
          elif hover.index == itemIndex: panelAltColor
          else: panelColor
        fillRect(rowRect, rowBg)
        if itemIndex == selectedIndex:
          fillRect(rect(rowRect.x, rowRect.y, 3, rowRect.h), accentColor)
        drawLine(rowRect.x, rowRect.y + rowRect.h - 1,
          rowRect.x + rowRect.w, rowRect.y + rowRect.h - 1, dividerColor)

        let boxRect = checkboxRect(rowRect)
        let delRect = deleteRect(rowRect)
        drawCheckbox(boxRect, items[itemIndex].done)
        drawDeleteButton(delRect, hover.kind == HoverDelete and hover.index == itemIndex)

        let textX = boxRect.x + boxRect.w + 10
        let maxTextWidth = delRect.x - textX - 10
        let shown = truncateText(font, items[itemIndex].text, maxTextWidth)
        let textY = rowRect.y + (rowRect.h - fm.lineHeight) div 2
        let fg =
          if items[itemIndex].done: mutedTextColor
          else: textColor
        discard drawText(font, textX, textY, shown, fg, rowBg)

        if items[itemIndex].done:
          let ext = measureText(font, shown)
          let strikeY = textY + fm.lineHeight div 2
          drawLine(textX, strikeY, textX + ext.w, strikeY, mutedTextColor)
    restoreState()

    fillRect(statusRect, panelColor)
    discard drawText(font, statusRect.x + 14, statusRect.y + 6,
      if openCount == 0 and items.len > 0: "All tasks completed"
      elif items.len == 0: "Ready"
      else: $openCount & " remaining",
      mutedTextColor, panelColor)

    refresh()
    sleep(16)

  closeFont(font)
  quitRequest()

main()
