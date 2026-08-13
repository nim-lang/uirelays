# Platform-independent screen/drawing relays.
# Part of the core stdlib abstraction (plan.md).

import coords

type
  Color* = object
    r*, g*, b*, a*: uint8

  Font* = distinct int    ## opaque handle; 0 = invalid
  Image* = distinct int   ## opaque handle; 0 = invalid

  FontStyle* {.pure.} = enum
    bold, italics
  FontStyles* = set[FontStyle]
    ## What a font is asked to look like beyond its size. `{}` is the upright
    ## regular face every driver can produce; the rest are a wish. A family
    ## without a bold or an italic face -- and a driver that cannot ask for one
    ## -- draws the regular face instead, so styled text is at worst plain,
    ## never missing.

  TextExtent* = object
    w*, h*: int

  FontMetrics* = object
    ascent*, descent*, lineHeight*: int

  ScreenLayout* = object
    ## Everything here is integers on purpose: a display's scale is either a
    ## whole number of device pixels per coordinate unit, or -- for the 125%
    ## and 150% displays where that is not true -- a percentage, which is
    ## still an integer.
    width*, height*: int  ## window size, in the unit the driver draws in
    pitch*: int
    scaleX*, scaleY*: int ## device pixels the driver *already* puts per
                          ## coordinate unit, so `width * scaleX` is the
                          ## physical width. Purely informational: an app
                          ## must not scale its own drawing by this.
    uiScale*: int         ## percent an app should enlarge its fonts and
                          ## hardcoded pixel sizes by to keep them physically
                          ## the same on any display. 100 means the driver or
                          ## the platform already accounts for the display's
                          ## density; 200 means the app draws twice as large.
    fullScreen*: bool

  CursorKind* = enum
    curDefault, curArrow, curIbeam, curWait,
    curCrosshair, curHand, curSizeNS, curSizeWE

  WindowRelays* = object
    createWindow*: proc (layout: var ScreenLayout) {.nimcall.}
    getWindowLayout*: proc (): ScreenLayout {.nimcall.}
    refresh*: proc () {.nimcall.}
    saveState*: proc () {.nimcall.}
    restoreState*: proc () {.nimcall.}
    setClipRect*: proc (r: Rect) {.nimcall.}
    setCursor*: proc (c: CursorKind) {.nimcall.}
    setWindowTitle*: proc (title: string) {.nimcall.}

  FontRelays* = object
    openFont*: proc (path: string; size: int; style: FontStyles;
                     metrics: var FontMetrics): Font {.nimcall.}
    closeFont*: proc (f: Font) {.nimcall.}
    getFontMetrics*: proc (f: Font): FontMetrics {.nimcall.}
    measureText*: proc (f: Font; text: string): TextExtent {.nimcall.}
    drawText*: proc (f: Font; x, y: int; text: string;
                     fg, bg: Color): TextExtent {.nimcall.}

  DrawRelays* = object
    fillRect*: proc (r: Rect; color: Color) {.nimcall.}
    drawLine*: proc (x1, y1, x2, y2: int; color: Color) {.nimcall.}
    drawPoint*: proc (x, y: int; color: Color) {.nimcall.}
    loadImage*: proc (path: string): Image {.nimcall.}
    freeImage*: proc (img: Image) {.nimcall.}
    drawImage*: proc (img: Image; src, dst: Rect) {.nimcall.}

proc `==`*(a, b: Font): bool {.borrow.}
proc `==`*(a, b: Image): bool {.borrow.}

var windowRelays* = WindowRelays(
  createWindow: proc (layout: var ScreenLayout) = discard,
  getWindowLayout: proc (): ScreenLayout =
    ScreenLayout(scaleX: 1, scaleY: 1, uiScale: 100),
  refresh: proc () = discard,
  saveState: proc () = discard,
  restoreState: proc () = discard,
  setClipRect: proc (r: Rect) = discard,
  setCursor: proc (c: CursorKind) = discard,
  setWindowTitle: proc (title: string) = discard)

var fontRelays* = FontRelays(
  openFont: proc (path: string; size: int; style: FontStyles;
                  metrics: var FontMetrics): Font = Font(0),
  closeFont: proc (f: Font) = discard,
  getFontMetrics: proc (f: Font): FontMetrics = FontMetrics(),
  measureText: proc (f: Font; text: string): TextExtent = TextExtent(),
  drawText: proc (f: Font; x, y: int; text: string;
                  fg, bg: Color): TextExtent = TextExtent())

var drawRelays* = DrawRelays(
  fillRect: proc (r: Rect; color: Color) = discard,
  drawLine: proc (x1, y1, x2, y2: int; color: Color) = discard,
  drawPoint: proc (x, y: int; color: Color) = discard,
  loadImage: proc (path: string): Image = Image(0),
  freeImage: proc (img: Image) = discard,
  drawImage: proc (img: Image; src, dst: Rect) = discard)

const
  MaxWindowWidth* = -1
    ## Pass as `createWindow`'s width for "every bit of width the desktop
    ## gives a window". See `MaxWindowHeight`.
  MaxWindowHeight* = -1
    ## Pass as `createWindow`'s height for "every bit of height the desktop
    ## gives a window" -- the screen minus the menu bar, the Dock, the
    ## taskbar, whatever the platform reserves.
    ##
    ## This is not `fullScreen`: the window keeps its title bar and its place
    ## among the other windows, and on macOS it does not move to a Space of
    ## its own. Either dimension can be given on its own, so a window can
    ## span the full width at a fixed height.

# Convenience wrappers
proc createWindow*(requestedW, requestedH: int; fullScreen = false): ScreenLayout =
  ## The defaults are what a driver that knows nothing about display density
  ## reports, so a driver only has to write back what it actually knows.
  ##
  ## `MaxWindowWidth` / `MaxWindowHeight` ask for as much space as a window
  ## may have. The layout that comes back always holds the real size in
  ## pixels -- the sentinel never survives the call, so the rest of an app
  ## never has to know about it.
  result = ScreenLayout(width: requestedW, height: requestedH,
                        scaleX: 1, scaleY: 1, uiScale: 100,
                        fullScreen: fullScreen)
  windowRelays.createWindow(result)

proc getWindowLayout*(): ScreenLayout =
  ## The current size and scale. Worth re-reading after the window moved to
  ## another monitor; `WindowMetricsEvent` reports the same numbers.
  windowRelays.getWindowLayout()

proc scaled*(layout: ScreenLayout; value: int): int =
  ## Enlarge a hardcoded font size or pixel dimension for this display.
  ## Integer arithmetic throughout, so 125% and 150% displays stay exact.
  value * layout.uiScale div 100

proc refresh*() = windowRelays.refresh()
proc saveState*() = windowRelays.saveState()
proc restoreState*() = windowRelays.restoreState()
proc setClipRect*(r: Rect) = windowRelays.setClipRect(r)
proc setCursor*(c: CursorKind) = windowRelays.setCursor(c)
proc setWindowTitle*(title: string) = windowRelays.setWindowTitle(title)

type
  StyledSlot = object
    ## What `styledFont` needs to open a bold or italic version of a font that
    ## is already open: the very arguments it was opened with.
    base: Font
    path: string
    size: int
    variants: array[3, Font]  ## {bold}, {italics}, {bold, italics}

var openedFonts: seq[StyledSlot]
  ## Only the upright fonts an app opened itself; the variants hang off them
  ## and are closed with them, so an app never has to know they exist.

proc variantIndex(style: FontStyles): int {.inline.} =
  ## `{bold}` -> 0, `{italics}` -> 1, `{bold, italics}` -> 2.
  result = (if FontStyle.bold in style: 1 else: 0) +
           (if FontStyle.italics in style: 2 else: 0) - 1

proc openFont*(path: string; size: int; metrics: var FontMetrics;
               style: FontStyles = {}): Font =
  ## `path` is a font file, or "" for the platform's monospaced default.
  ## A styled font asked for here is opened outright; `styledFont` is the way
  ## to get one from a font that is already open.
  result = fontRelays.openFont(path, size, style, metrics)
  if result.int != 0 and style == {}:
    openedFonts.add StyledSlot(base: result, path: path, size: size)

proc styledFont*(f: Font; style: FontStyles): Font =
  ## The same font in bold, in italics, or in both -- opened the first time it
  ## is asked for and closed together with `f`, so this can sit in a drawing
  ## loop.
  ##
  ## Hands back `f` itself when there is nothing to do: the plain style, a font
  ## this module never saw opened, or a face the driver could not produce. The
  ## worst case is text drawn upright, never text not drawn at all.
  if style == {} or f.int == 0: return f
  let k = variantIndex(style)
  for i in 0 ..< openedFonts.len:
    if openedFonts[i].base == f:
      if openedFonts[i].variants[k].int == 0:
        var metrics = FontMetrics()
        let v = fontRelays.openFont(openedFonts[i].path, openedFonts[i].size,
                                    style, metrics)
        # A failure is remembered as `f`, or every frame would try again.
        openedFonts[i].variants[k] = (if v.int == 0: f else: v)
      return openedFonts[i].variants[k]
  result = f

proc closeFont*(f: Font) =
  for i in 0 ..< openedFonts.len:
    if openedFonts[i].base == f:
      for v in openedFonts[i].variants:
        # `v == f` is the remembered failure above, closed once, below.
        if v.int != 0 and v != f: fontRelays.closeFont(v)
      openedFonts.del i
      break
  fontRelays.closeFont(f)

proc getFontMetrics*(f: Font): FontMetrics = fontRelays.getFontMetrics(f)
proc fontLineSkip*(f: Font): int = fontRelays.getFontMetrics(f).lineHeight
proc measureText*(f: Font; text: string): TextExtent =
  fontRelays.measureText(f, text)
proc drawText*(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
  fontRelays.drawText(f, x, y, text, fg, bg)

proc fillRect*(r: Rect; color: Color) = drawRelays.fillRect(r, color)
proc drawLine*(x1, y1, x2, y2: int; color: Color) =
  drawRelays.drawLine(x1, y1, x2, y2, color)
proc drawPoint*(x, y: int; color: Color) = drawRelays.drawPoint(x, y, color)
proc loadImage*(path: string): Image = drawRelays.loadImage(path)
proc freeImage*(img: Image) = drawRelays.freeImage(img)
proc drawImage*(img: Image; src, dst: Rect) = drawRelays.drawImage(img, src, dst)

# Color constructors
proc color*(r, g, b: uint8; a: uint8 = 255): Color =
  Color(r: r, g: g, b: b, a: a)
