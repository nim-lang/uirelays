# FigDraw + siwin backend driver. Uses siwin for window/input and FigDraw's
# atlas-backed renderer for drawing/text/images.

when defined(macosx):
  {.passC: "-Wno-incompatible-function-pointer-types".}

import std/[deques, hashes, math, monotimes, os, tables, times, unicode]

import pixie
import pixie/fonts
import vmath
import chroma
import bumpy

import siwin
import siwin/platforms/any/[clipboards]

import figdraw/commons
import figdraw/figrender
import figdraw/windowing/siwinshim
import figdraw/extras/systemfonts
import figdraw/common/[fontglyphs, fonttypes, fontutils, typefaces]

import ../coords, ../input, ../screen
import ./siwin_keys

type
  DrawState = object
    clipActive: bool
    clipRect: coords.Rect

  FontSlot = object
    uiFont: FigFont
    pixieFont: pixie.Font
    metrics: FontMetrics

  ImageSlot = object
    image: pixie.Image

  PixelUploadSlot = object
    key: Hash
    pixelsKey: Hash
    width, height: int
    generation: uint64

  DrawOpKind = enum
    dopFillRect
    dopLine
    dopPoint
    dopText
    dopImage
    dopPixels

  DrawOp = object
    state: DrawState
    case kind: DrawOpKind
    of dopFillRect:
      rect: coords.Rect
      fillColor: screen.Color
    of dopLine:
      x1, y1, x2, y2: int
      lineColor: screen.Color
    of dopPoint:
      px, py: int
      pointColor: screen.Color
    of dopText:
      font: screen.Font
      tx, ty: int
      text: string
      fg, bg: screen.Color
    of dopImage:
      image: screen.Image
      src, dst: coords.Rect
    of dopPixels:
      pixels: pixie.Image
      pixelsKey: Hash
      pixelsDst: coords.Rect

var
  appWindow: siwin.Window
  appGlobals: SiwinGlobals
  renderer: FigRenderer[SiwinRenderBackend]
  useAutoScale: bool
  eventQueue: Deque[input.Event]
  fontSlots: seq[FontSlot]
  images: seq[ImageSlot]
  drawOps: seq[DrawOp]
  stateStack: seq[DrawState]
  currentState: DrawState
  typefaceIdsByPath: Table[string, TypefaceId]
  siwinInitialized = false
  frameStarted = false
  presentationPending = false
  pixelUploadSlots: seq[PixelUploadSlot]

proc toFigColor(c: screen.Color): chroma.Color =
  rgba(c.r, c.g, c.b, c.a).color

proc toFill(c: screen.Color): Fill =
  fill(rgba(c.r, c.g, c.b, c.a))

proc scaledF(v: int): float32 {.inline.} =
  scaled(v.float32)

proc scaledRect(r: coords.Rect): bumpy.Rect {.inline.} =
  rect(scaledF(r.x), scaledF(r.y), scaledF(r.w), scaledF(r.h))

proc currentScale(): float32 =
  if appWindow.isNil:
    return 1.0
  let scale = appWindow.inputDeviceScale()
  if scale > 0: scale else: 1.0

proc toLogicalCoord(v: float32): int =
  (v / currentScale()).round().int

proc toLogicalSize(v: int32): int =
  (v.float32 / currentScale()).round().int

proc queueEvent(e: input.Event) =
  eventQueue.addLast(e)

proc resolveFontPath(path: string): string =
  ## An empty path means "the platform default", and for this library that is
  ## a *monospaced* font: the native drivers pick Consolas (Windows) and
  ## fontconfig's `monospace` (X11), and the apps are text editors that expect
  ## a fixed advance. So the candidate lists here are mono-only too -- a
  ## proportional fallback would silently break column arithmetic.
  ##
  ## Only `.ttf`/`.otf` are listed: pixie's `readTypeface` rejects anything
  ## else, so macOS' `.ttc` collections (Menlo, Courier) are unreachable from
  ## here, and SFNSMono.ttf is a variable font whose default instance is the
  ## too-thin Light weight.
  if path.len > 0:
    return path

  when defined(windows):
    let candidates = [
      "Consolas",
      "consola.ttf",
      "Courier New",
      "cour.ttf"
    ]
  elif defined(macosx):
    let candidates = [
      "Monaco.ttf",
      "Andale Mono.ttf",
      "Courier New.ttf",
      "DejaVuSansMono.ttf"
    ]
  else:
    let candidates = [
      "DejaVuSansMono.ttf",
      "LiberationMono-Regular.ttf",
      "NotoSansMono[wdth,wght].ttf",
      "monospace"
    ]

  for candidate in candidates:
    if fileExists(candidate):
      return candidate
    let systemPath = findSystemFontFile([candidate, splitFile(candidate).name])
    if systemPath.len > 0:
      return systemPath

  ""

proc getFontSlot(f: screen.Font): ptr FontSlot =
  let idx = f.int - 1
  if idx >= 0 and idx < fontSlots.len:
    return fontSlots[idx].addr
  nil

proc getImageSlot(img: screen.Image): ptr ImageSlot =
  let idx = img.int - 1
  if idx >= 0 and idx < images.len:
    return images[idx].addr
  nil

proc pushCurrentRenderRequest() =
  queueEvent(input.Event(kind: NoEvent))

proc handleRenderRequest() =
  # refresh() requests one window service to present the submitted frame.
  # An expose requests an application repaint, but our own presentation must
  # not request another repaint and feed an event-driven redraw loop forever.
  if presentationPending:
    presentationPending = false
  else:
    pushCurrentRenderRequest()

proc queueTextEvent(text: string) =
  var e = input.Event(kind: TextInputEvent)
  if text.len > 0:
    for i in 0 .. min(3, text.high):
      e.text[i] = text[i]
  queueEvent(e)

proc applyClip(ctx: BackendContext; state: DrawState): bool =
  if not state.clipActive:
    return false
  let clipRect = scaledRect(state.clipRect)
  ctx.beginMask(clipRect, [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32])
  ctx.endMask()
  true

proc replayText(ctx: BackendContext; op: DrawOp) =
  let slot = getFontSlot(op.font)
  if slot.isNil or op.text.len == 0:
    return

  let textBox = rect(0.0'f32, 0.0'f32, 1_000_000.0'f32, 1_000_000.0'f32)
  let layout = typeset(
    textBox,
    [span(slot.uiFont, toFill(op.fg), op.text)],
    hAlign = Left,
    vAlign = Top,
    minContent = false,
    wrap = false,
  )
  let ext = layout.bounding
  if ext.w > 0 and ext.h > 0 and op.bg.a > 0'u8:
    ctx.drawRect(
      rect(scaledF(op.tx), scaledF(op.ty), scaled(ext.w), scaled(ext.h)),
      toFigColor(op.bg),
    )

  let lcdFiltering = renderer.textLcdFiltering()
  let subpixelPositioning = renderer.textSubpixelPositioning()
  let glyphVariants = subpixelPositioning and renderer.textSubpixelGlyphVariants()

  for glyph in layout.glyphs():
    if unicode.isWhiteSpace(glyph.rune):
      continue
    var
      glyphPos = vec2(glyph.pos.x, glyph.pos.y - glyph.descent)
      subpixelShift = 0.0'f32
      subpixelVariant = 0
    if subpixelPositioning:
      let snappedX = floor(glyphPos.x)
      let fractionalX = max(0.0'f32, min(glyphPos.x - snappedX, 0.999'f32))
      glyphPos.x = snappedX
      if glyphVariants:
        subpixelVariant = toGlyphVariantSubpixelStep(fractionalX)
      else:
        subpixelShift = fractionalX

    let glyphId = glyph.hash(
      lcdFiltering = lcdFiltering,
      subpixelVariant = subpixelVariant,
    )
    renderer.ctx.setTextSubpixelShift(subpixelShift)
    if glyphId notin renderer.ctx.entries():
      let img = glyph.generateGlyph(
        lcdFiltering = lcdFiltering,
        subpixelVariant = subpixelVariant,
        force = true,
        upload = false,
      )
      if img != nil:
        renderer.ctx.putImage(glyphId, img)
    if glyphId in renderer.ctx.entries():
      renderer.ctx.drawImage(
        glyphId,
        vec2(scaledF(op.tx) + scaled(glyphPos.x), scaledF(op.ty) + scaled(glyphPos.y)),
        [rgba(op.fg.r, op.fg.g, op.fg.b, op.fg.a),
         rgba(op.fg.r, op.fg.g, op.fg.b, op.fg.a),
         rgba(op.fg.r, op.fg.g, op.fg.b, op.fg.a),
         rgba(op.fg.r, op.fg.g, op.fg.b, op.fg.a)],
        false,
      )
    renderer.ctx.setTextSubpixelShift(0.0'f32)

proc replayImage(ctx: BackendContext; op: DrawOp) =
  let slot = getImageSlot(op.image)
  if slot.isNil or slot.image.isNil:
    return
  let key = hash((op.image.int, op.src.x, op.src.y, op.src.w, op.src.h))
  if key notin ctx.entries():
    let cropped =
      if op.src.x == 0 and op.src.y == 0 and
         op.src.w == slot.image.width and op.src.h == slot.image.height:
        slot.image
      else:
        try:
          slot.image.subImage(op.src.x, op.src.y, op.src.w, op.src.h)
        except PixieError:
          return
    ctx.putImage(key, cropped)
  ctx.drawImage(
    key,
    vec2(scaledF(op.dst.x), scaledF(op.dst.y)),
    toFigColor(color(255, 255, 255, 255)),
    vec2(scaledF(op.dst.w), scaledF(op.dst.h)),
    false,
  )

proc replayPixels(ctx: BackendContext; op: DrawOp; index: int) =
  ## One atlas slot per blit position in a frame, reused across animation frames.
  ## Content hashes avoid uploads for unchanged pictures; changed pixels update
  ## the same rectangle instead of growing the atlas for every animation frame.
  if op.pixels.isNil:
    return
  if index >= pixelUploadSlots.len:
    pixelUploadSlots.setLen(index + 1)
    pixelUploadSlots[index].key = hash(("uirelays-pixel-slot", index))
  let slot = addr pixelUploadSlots[index]
  if slot.key notin ctx.entries() or slot.width != op.pixels.width or
      slot.height != op.pixels.height:
    if slot.key in ctx.entries():
      ctx.removeAtlasEntry(slot.key)
    ctx.putImage(slot.key, op.pixels)
  elif slot.generation != ctx.atlasGeneration() or slot.pixelsKey != op.pixelsKey:
    ctx.updateImage(slot.key, op.pixels)
  slot.pixelsKey = op.pixelsKey
  slot.width = op.pixels.width
  slot.height = op.pixels.height
  slot.generation = ctx.atlasGeneration()
  ctx.drawImage(
    slot.key,
    vec2(scaledF(op.pixelsDst.x), scaledF(op.pixelsDst.y)),
    toFigColor(color(255, 255, 255, 255)),
    vec2(scaledF(op.pixelsDst.w), scaledF(op.pixelsDst.h)),
    false,
  )

proc renderQueuedOps() =
  if appWindow.isNil or appWindow.closed or renderer.isNil:
    return
  renderer.beginFrame()
  let frameSize = appWindow.logicalSize()
  renderer.ctx.beginFrame(
    frameSize.scaled(),
    clearMain = true,
    clearMainColor = rgba(0, 0, 0, 0).color,
  )
  let ctx: BackendContext = renderer.ctx
  ctx.saveTransform()
  ctx.scale(ctx.pixelScale)
  var pixelIndex = 0
  for op in drawOps:
    let hasClip = applyClip(ctx, op.state)
    case op.kind
    of dopFillRect:
      ctx.drawRect(scaledRect(op.rect), toFigColor(op.fillColor))
    of dopLine:
      let dx = scaledF(op.x2 - op.x1)
      let dy = scaledF(op.y2 - op.y1)
      let length = hypot(dx, dy)
      if length > 0.0:
        ctx.saveTransform()
        ctx.translate(vec2(scaledF(op.x1), scaledF(op.y1)))
        ctx.rotate(arctan2(dy, dx))
        ctx.drawRect(
          rect(0.0'f32, -scaled(0.5'f32), length, scaled(1.0'f32)),
          toFigColor(op.lineColor),
        )
        ctx.restoreTransform()
    of dopPoint:
      ctx.drawRect(
        rect(scaledF(op.px), scaledF(op.py), scaled(1.0'f32), scaled(1.0'f32)),
        toFigColor(op.pointColor),
      )
    of dopText:
      replayText(ctx, op)
    of dopImage:
      replayImage(ctx, op)
    of dopPixels:
      replayPixels(ctx, op, pixelIndex)
      inc pixelIndex
    if hasClip:
      ctx.popMask()
  ctx.restoreTransform()
  ctx.endFrame()
  renderer.endFrame()
  drawOps.setLen(0)

proc figCreateWindow(layout: var ScreenLayout; icon: pointer; iconLen: int) =
  # MaxWindowWidth/MaxWindowHeight arrive as negative sizes. Neither backend
  # is available to test against here, so this driver does the safe half of
  # the contract: it substitutes a sane size instead of handing a negative one
  # to the toolkit. The window is then merely large, not maximized -- wiring
  # that up is a one-liner once the backend's own maximize can be verified.
  if layout.width < 0: layout.width = 1024
  if layout.height < 0: layout.height = 768
  if not siwinInitialized:
    renderer = newFigRenderer(atlasSize = 1024, backendState = SiwinRenderBackend())
    appWindow = newSiwinWindow(
      size = ivec2(layout.width.int32, layout.height.int32),
      fullscreen = layout.fullScreen,
      title = "uirelays",
    )
    useAutoScale = appWindow.configureUiScale()
    appGlobals = sharedSiwinGlobals()
    renderer.setupBackend(appWindow)
    appWindow.eventsHandler = WindowEventsHandler(
      onClose: proc(e: CloseEvent) =
        queueEvent(input.Event(kind: WindowCloseEvent)),
      onRender: proc(e: RenderEvent) =
        handleRenderRequest(),
      onResize: proc(e: ResizeEvent) =
        appWindow.refreshUiScale(useAutoScale)
        let scale = currentScale().round().int
        queueEvent(input.Event(
          kind: WindowMetricsEvent,
          x: toLogicalSize(e.size.x),
          y: toLogicalSize(e.size.y),
          scaleX: scale,
          scaleY: scale,
          uiScale: 100,
        )),
      onStateBoolChanged: proc(e: StateBoolChangedEvent) =
        case e.kind
        of siwin.StateBoolChangedEventKind.focus:
          queueEvent(input.Event(
            kind: if e.value: WindowFocusGainedEvent else: WindowFocusLostEvent
          ))
        else:
          discard,
      onKey: proc(e: KeyEvent) =
        queueEvent(input.Event(
          kind: if e.pressed: KeyDownEvent else: KeyUpEvent,
          key: translateKey(e.key),
          mods: translateMods(e.modifiers),
        )),
      onTextInput: proc(e: siwin.TextInputEvent) =
        queueTextEvent(e.text),
      onMouseMove: proc(e: siwin.MouseMoveEvent) =
        queueEvent(input.Event(
          kind: MouseMoveEvent,
          x: toLogicalCoord(e.pos.x),
          y: toLogicalCoord(e.pos.y),
        )),
      onMouseButton: proc(e: siwin.MouseButtonEvent) =
        queueEvent(input.Event(
          kind: if e.pressed: MouseDownEvent else: MouseUpEvent,
          x: toLogicalCoord(e.window.mouse.pos.x),
          y: toLogicalCoord(e.window.mouse.pos.y),
          button: translateButton(e.button),
          clicks: 1,
        )),
      onClick: proc(e: siwin.ClickEvent) =
        if eventQueue.len > 0:
          var last = eventQueue.popLast()
          if last.kind == MouseDownEvent or last.kind == MouseUpEvent:
            last.clicks = if e.double: 2 else: 1
          eventQueue.addLast(last),
      onScroll: proc(e: siwin.ScrollEvent) =
        queueEvent(input.Event(
          kind: MouseWheelEvent,
          x: e.deltaX.round().int,
          y: e.delta.round().int,
        )),
    )
    appWindow.firstStep()
    siwinInitialized = true
    frameStarted = true

  appWindow.refreshUiScale(useAutoScale)
  let size = appWindow.logicalSize()
  layout.width = size.x.round().int
  layout.height = size.y.round().int
  # FigDraw already rasterizes at the window's scale, fractional values
  # included, so the app draws in logical units and enlarges nothing.
  layout.scaleX = currentScale().round().int
  layout.scaleY = currentScale().round().int
  layout.uiScale = 100

proc figGetWindowLayout(): ScreenLayout =
  if appWindow.isNil:
    return ScreenLayout(scaleX: 1, scaleY: 1, uiScale: 100)
  let size = appWindow.logicalSize()
  let scale = currentScale().round().int
  ScreenLayout(width: size.x.round().int, height: size.y.round().int,
               scaleX: scale, scaleY: scale, uiScale: 100)

proc figRefresh() =
  if appWindow.isNil or appWindow.closed:
    drawOps.setLen(0)
    return
  renderQueuedOps()
  presentationPending = true
  appWindow.redraw()

proc figSaveState() =
  stateStack.add currentState

proc figRestoreState() =
  if stateStack.len > 0:
    currentState = stateStack.pop()
  else:
    currentState = DrawState()

proc figSetClipRect(r: coords.Rect) =
  currentState.clipActive = true
  currentState.clipRect = r

proc figOpenFont(path: string; size: int; style: FontStyles;
                 metrics: var FontMetrics): screen.Font =
  # `style` is accepted and ignored: pixie draws the typeface in the file it
  # was handed and has nothing to synthesize a bold or an italic cut with, so
  # styled text comes out upright here. Picking a sibling file -- the
  # `-Bold.ttf` next to the `-Regular.ttf` -- is the way to fix that, once
  # there is a machine to try it on.
  let resolvedPath = resolveFontPath(path)
  if resolvedPath.len == 0:
    return screen.Font(0)
  let typefaceId =
    if resolvedPath in typefaceIdsByPath:
      typefaceIdsByPath[resolvedPath]
    else:
      try:
        let id = loadTypeface(resolvedPath)
        typefaceIdsByPath[resolvedPath] = id
        id
      except PixieError:
        return screen.Font(0)
  let uiFont = FigFont(typefaceId: typefaceId, size: size.float32)
  let (_, pf) = convertFont(uiFont)
  metrics.ascent = round(pf.typeface.ascent * pf.scale).int
  metrics.descent = round(pf.typeface.descent * pf.scale).int
  metrics.lineHeight = round(
    if pf.lineHeight > 0: pf.lineHeight else: pf.defaultLineHeight()
  ).int
  fontSlots.add FontSlot(uiFont: uiFont, pixieFont: pf, metrics: metrics)
  screen.Font(fontSlots.len)

proc figCloseFont(f: screen.Font) =
  discard f

proc figMeasureText(f: screen.Font; text: string): TextExtent =
  let slot = getFontSlot(f)
  if slot.isNil or text.len == 0:
    return
  let layout = slot.pixieFont.typeset(text)
  let bounds = layout.layoutBounds()
  result = TextExtent(w: ceil(bounds.x).int, h: ceil(bounds.y).int)

proc figDrawText(f: screen.Font; x, y: int; text: string;
                 fg, bg: screen.Color): TextExtent =
  result = figMeasureText(f, text)
  drawOps.add DrawOp(
    kind: dopText,
    state: currentState,
    font: f,
    tx: x,
    ty: y,
    text: text,
    fg: fg,
    bg: bg,
  )

proc figRenderText(f: screen.Font; text: string; fg: screen.Color;
                   pixels: var seq[uint32]): TextExtent =
  ## Pixie fills the run into an image of its own, premultiplied as the
  ## pixels `renderText` hands out are.
  pixels.setLen 0
  let slot = getFontSlot(f)
  if slot.isNil or slot.pixieFont.isNil or text.len == 0:
    return
  let size = figMeasureText(f, text)
  if size.w <= 0 or size.h <= 0:
    return
  let font = slot.pixieFont.copy()
  font.paint = toFigColor(fg)
  let image = newImage(size.w, size.h)
  try:
    image.fillText(font.typeset(text))
  except PixieError:
    return
  pixels.setLen size.w * size.h
  for i, c in image.data:
    pixels[i] = (c.a.uint32 shl 24) or (c.r.uint32 shl 16) or
                (c.g.uint32 shl 8) or c.b.uint32
  result = size

proc figGetFontMetrics(f: screen.Font): FontMetrics =
  let slot = getFontSlot(f)
  if not slot.isNil:
    result = slot.metrics

proc figFillRect(r: coords.Rect; color: screen.Color) =
  drawOps.add DrawOp(kind: dopFillRect, state: currentState, rect: r, fillColor: color)

proc figDrawLine(x1, y1, x2, y2: int; color: screen.Color) =
  drawOps.add DrawOp(
    kind: dopLine,
    state: currentState,
    x1: x1, y1: y1, x2: x2, y2: y2,
    lineColor: color,
  )

proc figDrawPoint(x, y: int; color: screen.Color) =
  drawOps.add DrawOp(kind: dopPoint, state: currentState, px: x, py: y, pointColor: color)

proc figLoadImage(path: string): screen.Image =
  try:
    images.add ImageSlot(image: pixie.readImage(path))
    screen.Image(images.len)
  except PixieError:
    screen.Image(0)

proc figFreeImage(img: screen.Image) =
  let idx = img.int - 1
  if idx >= 0 and idx < images.len:
    images[idx].image = nil

proc figDrawImage(img: screen.Image; src, dst: coords.Rect) =
  if img == screen.Image(0):
    return
  drawOps.add DrawOp(kind: dopImage, state: currentState, image: img, src: src, dst: dst)

proc figImageSize(img: screen.Image): tuple[w, h: int] =
  ## Without this a caller can crop a picture but cannot ask for all of it,
  ## because "all of it" is a rectangle in the picture's own pixels and it had
  ## no way to learn how many there are.
  let slot = getImageSlot(img)
  if slot.isNil or slot.image.isNil: (0, 0)
  else: (slot.image.width, slot.image.height)

proc queueRGBA(pixels: ptr UncheckedArray[uint32]; w, h, stride: int;
               dst: coords.Rect; format: RGBAFormat): bool =
  if pixels == nil or w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0:
    return false
  # Deferred replay owns a copy; the caller may reuse its buffer on return.
  var img = pixie.newImage(w, h)
  var key = hash((w, h, format))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let p = pixels[y * stride + x]
      img.data[y * w + x] = rgbx(uint8((p shr 16) and 0xFF),
                                uint8((p shr 8) and 0xFF),
                                uint8(p and 0xFF),
                                if format == RGBAFormat.argbPremultiplied: uint8(p shr 24) else: 255'u8)
      key = key !& hash(p)
  drawOps.add DrawOp(kind: dopPixels, state: currentState,
                    pixels: img, pixelsKey: !$key, pixelsDst: dst)
  true

proc figDrawRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                 dst: coords.Rect; format: RGBAFormat): bool =
  queueRGBA(pixels, w, h, w, dst, format)

proc figBlitRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                 dst: coords.Rect; format: RGBAFormat): bool =
  if pixels == nil or w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0:
    return false
  # Preserve blitRGBA's clipping-only contract, including the source stride.
  let cw = min(w, dst.w)
  let ch = min(h, dst.h)
  queueRGBA(pixels, cw, ch, w, coords.rect(dst.x, dst.y, cw, ch), format)


proc figSetCursor(c: screen.CursorKind) =
  if appWindow.isNil or appWindow.closed:
    return
  appWindow.cursor = Cursor(kind: siwin.CursorKind.builtin, builtin: case c
    of curDefault, curArrow: BuiltinCursor.arrow
    of curIbeam: BuiltinCursor.text
    of curWait: BuiltinCursor.wait
    of curCrosshair: BuiltinCursor.cross
    of curHand: BuiltinCursor.pointingHand
    of curSizeNS: BuiltinCursor.sizeVertical
    of curSizeWE: BuiltinCursor.sizeHorizontal)

proc figSetWindowTitle(title: string) =
  if not appWindow.isNil and appWindow.opened:
    appWindow.title = title

proc figGetClipboardText(): string =
  if appWindow.isNil: ""
  else: appWindow.clipboard.text

proc figPutClipboardText(text: string) =
  if not appWindow.isNil:
    appWindow.clipboard.text = text

proc pumpWindowEvents() =
  if not appWindow.isNil and appWindow.opened:
    discard appGlobals.pollEvents()
    appWindow.serviceWindow()

proc figPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  discard flags
  if eventQueue.len == 0:
    pumpWindowEvents()
  if eventQueue.len == 0:
    return false
  e = eventQueue.popFirst()
  true

proc figWaitEvent(e: var input.Event; timeoutMs: int; flags: set[InputFlag]): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = max(timeoutMs, 0))
  if figPollEvent(e, flags):
    return true
  while not appWindow.isNil and appWindow.opened:
    let remaining =
      if timeoutMs < 0: high(Duration)
      else: deadline - getMonoTime()
    if timeoutMs >= 0 and remaining.inNanoseconds <= 0:
      return false
    let activity = appGlobals.waitEvents(remaining)
    if appWindow.opened:
      appWindow.serviceWindow()
    if eventQueue.len > 0:
      e = eventQueue.popFirst()
      return true
    if activity == eventTimeout:
      return false
  false

proc figGetTicks(): int =
  (epochTime() * 1000).int

proc figDelay(ms: int) =
  os.sleep(ms)

proc figShutdown() =
  if not appWindow.isNil and appWindow.opened:
    close(appWindow)
  appWindow = nil
  appGlobals = nil
  renderer = nil
  eventQueue.clear()
  drawOps.setLen(0)
  stateStack.setLen(0)
  currentState = DrawState()
  fontSlots.setLen(0)
  images.setLen(0)
  typefaceIdsByPath.clear()
  pixelUploadSlots.setLen(0)
  siwinInitialized = false
  frameStarted = false
  presentationPending = false

proc initFigDrawSiwinDriver*() =
  windowRelays = WindowRelays(
    createWindow: figCreateWindow,
    getWindowLayout: figGetWindowLayout,
    refresh: figRefresh,
    saveState: figSaveState,
    restoreState: figRestoreState,
    setClipRect: figSetClipRect,
    setCursor: figSetCursor,
    setWindowTitle: figSetWindowTitle,
  )
  fontRelays = FontRelays(
    openFont: figOpenFont,
    closeFont: figCloseFont,
    getFontMetrics: figGetFontMetrics,
    measureText: figMeasureText,
    drawText: figDrawText,
    renderText: figRenderText,
  )
  drawRelays = DrawRelays(
    fillRect: figFillRect,
    drawLine: figDrawLine,
    drawPoint: figDrawPoint,
    loadImage: figLoadImage,
    freeImage: figFreeImage,
    drawImage: figDrawImage,
    imageSize: figImageSize,
    blitRGBA: figBlitRGBA,
    drawRGBA: figDrawRGBA,
  )
  inputRelays = InputRelays(
    pollEvent: figPollEvent,
    waitEvent: figWaitEvent,
    getTicks: figGetTicks,
    sleep: figDelay,
    shutdown: figShutdown,
  )
  clipboardRelays = ClipboardRelays(
    getText: figGetClipboardText,
    putText: figPutClipboardText,
  )
