# FigDraw + Windy backend driver. Uses Windy for window/input and FigDraw's
# atlas-backed renderer for drawing/text/images.

when defined(macosx):
  {.passC: "-Wno-incompatible-function-pointer-types".}

import std/[deques, hashes, math, monotimes, os, tables, times, unicode]

import pixie
import pixie/fonts
import vmath
import chroma
import bumpy

import figdraw/commons
import figdraw/figrender
import figdraw/windowing/windyshim
import figdraw/extras/systemfonts
import figdraw/common/[fontglyphs, fonttypes, fontutils, typefaces]

import ../coords, ../input, ../screen

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

  DrawOpKind = enum
    dopFillRect
    dopLine
    dopPoint
    dopText
    dopImage

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

var
  appWindow: Window
  renderer: FigRenderer[WindyRenderBackend]
  eventQueue: Deque[input.Event]
  fontSlots: seq[FontSlot]
  images: seq[ImageSlot]
  drawOps: seq[DrawOp]
  stateStack: seq[DrawState]
  currentState: DrawState
  typefaceIdsByPath: Table[string, TypefaceId]
  windyInitialized = false
  ticksStart = getMonoTime()

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
  let scale = appWindow.contentScale()
  if scale > 0: scale else: 1.0

proc toLogicalCoord(v: int32): int =
  (v.float32 / currentScale()).round().int

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

proc currentMods(): set[input.Modifier] =
  if appWindow.buttonDown[KeyLeftShift] or appWindow.buttonDown[KeyRightShift]:
    result.incl ShiftPressed
  if appWindow.buttonDown[KeyLeftControl] or appWindow.buttonDown[KeyRightControl]:
    result.incl CtrlPressed
  if appWindow.buttonDown[KeyLeftAlt] or appWindow.buttonDown[KeyRightAlt]:
    result.incl AltPressed
  if appWindow.buttonDown[KeyLeftSuper] or appWindow.buttonDown[KeyRightSuper]:
    result.incl GuiPressed

proc translateKey(k: Button): input.KeyCode =
  case k
  of Button.KeyA: input.KeyA
  of Button.KeyB: input.KeyB
  of Button.KeyC: input.KeyC
  of Button.KeyD: input.KeyD
  of Button.KeyE: input.KeyE
  of Button.KeyF: input.KeyF
  of Button.KeyG: input.KeyG
  of Button.KeyH: input.KeyH
  of Button.KeyI: input.KeyI
  of Button.KeyJ: input.KeyJ
  of Button.KeyK: input.KeyK
  of Button.KeyL: input.KeyL
  of Button.KeyM: input.KeyM
  of Button.KeyN: input.KeyN
  of Button.KeyO: input.KeyO
  of Button.KeyP: input.KeyP
  of Button.KeyQ: input.KeyQ
  of Button.KeyR: input.KeyR
  of Button.KeyS: input.KeyS
  of Button.KeyT: input.KeyT
  of Button.KeyU: input.KeyU
  of Button.KeyV: input.KeyV
  of Button.KeyW: input.KeyW
  of Button.KeyX: input.KeyX
  of Button.KeyY: input.KeyY
  of Button.KeyZ: input.KeyZ
  of Button.Key0: input.Key0
  of Button.Key1: input.Key1
  of Button.Key2: input.Key2
  of Button.Key3: input.Key3
  of Button.Key4: input.Key4
  of Button.Key5: input.Key5
  of Button.Key6: input.Key6
  of Button.Key7: input.Key7
  of Button.Key8: input.Key8
  of Button.Key9: input.Key9
  of Button.KeyF1: input.KeyF1
  of Button.KeyF2: input.KeyF2
  of Button.KeyF3: input.KeyF3
  of Button.KeyF4: input.KeyF4
  of Button.KeyF5: input.KeyF5
  of Button.KeyF6: input.KeyF6
  of Button.KeyF7: input.KeyF7
  of Button.KeyF8: input.KeyF8
  of Button.KeyF9: input.KeyF9
  of Button.KeyF10: input.KeyF10
  of Button.KeyF11: input.KeyF11
  of Button.KeyF12: input.KeyF12
  of Button.KeyEnter, Button.NumpadEnter: input.KeyEnter
  of Button.KeySpace: input.KeySpace
  of Button.KeyEscape: input.KeyEsc
  of Button.KeyTab: input.KeyTab
  of Button.KeyBackspace: input.KeyBackspace
  of Button.KeyDelete: input.KeyDelete
  of Button.KeyInsert: input.KeyInsert
  of Button.KeyLeft: input.KeyLeft
  of Button.KeyRight: input.KeyRight
  of Button.KeyUp: input.KeyUp
  of Button.KeyDown: input.KeyDown
  of Button.KeyPageUp: input.KeyPageUp
  of Button.KeyPageDown: input.KeyPageDown
  of Button.KeyHome: input.KeyHome
  of Button.KeyEnd: input.KeyEnd
  of Button.KeyCapsLock: input.KeyCapslock
  of Button.KeyComma: input.KeyComma
  of Button.KeyPeriod: input.KeyPeriod
  of Button.KeySlash, Button.NumpadDivide: input.KeySlash
  of Button.KeyMinus, Button.NumpadSubtract: input.KeyMinus
  of Button.KeyEqual, Button.NumpadEqual: input.KeyEqual
  of Button.NumpadAdd: input.KeyPlus
  else: KeyNone

proc translateButton(btn: Button): input.MouseButton =
  case btn
  of MouseLeft: LeftButton
  of MouseRight: RightButton
  of MouseMiddle: MiddleButton
  else: LeftButton

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

proc renderQueuedOps() =
  if appWindow.isNil or renderer.isNil:
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
    if hasClip:
      ctx.popMask()
  ctx.restoreTransform()
  ctx.endFrame()
  renderer.endFrame()
  drawOps.setLen(0)

proc figCreateWindow(layout: var ScreenLayout) =
  # MaxWindowWidth/MaxWindowHeight arrive as negative sizes. Neither backend
  # is available to test against here, so this driver does the safe half of
  # the contract: it substitutes a sane size instead of handing a negative one
  # to the toolkit. The window is then merely large, not maximized -- wiring
  # that up is a one-liner once the backend's own maximize can be verified.
  if layout.width < 0: layout.width = 1024
  if layout.height < 0: layout.height = 768
  if not windyInitialized:
    appWindow = newWindyWindow(
      size = ivec2(layout.width.int32, layout.height.int32),
      fullscreen = layout.fullScreen,
      title = "uirelays",
    )
    setFigUiScale(appWindow.contentScale())
    renderer = newFigRenderer(
      atlasSize = 1024, backendState = WindyRenderBackend())
    renderer.setupBackend(appWindow)
    appWindow.runeInputEnabled = true
    appWindow.onCloseRequest = proc() =
      queueEvent(input.Event(kind: WindowCloseEvent))
    appWindow.onResize = proc() =
      setFigUiScale(appWindow.contentScale())
      let size = appWindow.size()
      let scale = currentScale().round().int
      queueEvent(input.Event(
        kind: WindowMetricsEvent,
        x: toLogicalSize(size.x),
        y: toLogicalSize(size.y),
        scaleX: scale,
        scaleY: scale,
        uiScale: 100,
      ))
    appWindow.onFocusChange = proc() =
      queueEvent(input.Event(
        kind: if appWindow.focused():
          WindowFocusGainedEvent
        else:
          WindowFocusLostEvent
      ))
    appWindow.onMouseMove = proc() =
      let pos = appWindow.mousePos()
      queueEvent(input.Event(
        kind: MouseMoveEvent,
        x: toLogicalCoord(pos.x),
        y: toLogicalCoord(pos.y),
      ))
    appWindow.onScroll = proc() =
      let delta = appWindow.scrollDelta()
      queueEvent(input.Event(
        kind: MouseWheelEvent,
        x: delta.x.round().int,
        y: delta.y.round().int,
      ))
    appWindow.onButtonPress = proc(button: Button) =
      if button in {MouseLeft, MouseRight, MouseMiddle}:
        let pos = appWindow.mousePos()
        queueEvent(input.Event(
          kind: MouseDownEvent,
          mods: currentMods(),
          x: toLogicalCoord(pos.x),
          y: toLogicalCoord(pos.y),
          button: translateButton(button),
          clicks: 1,
        ))
      elif button in {DoubleClick, TripleClick, QuadrupleClick}:
        if eventQueue.len > 0:
          var last = eventQueue.popLast()
          if last.kind == MouseDownEvent:
            last.clicks = ord(button) - ord(DoubleClick) + 2
          eventQueue.addLast(last)
      else:
        queueEvent(input.Event(
          kind: KeyDownEvent,
          key: translateKey(button),
          mods: currentMods(),
        ))
    appWindow.onButtonRelease = proc(button: Button) =
      if button in {MouseLeft, MouseRight, MouseMiddle}:
        let pos = appWindow.mousePos()
        queueEvent(input.Event(
          kind: MouseUpEvent,
          mods: currentMods(),
          x: toLogicalCoord(pos.x),
          y: toLogicalCoord(pos.y),
          button: translateButton(button),
          clicks: 1,
        ))
      elif button notin {DoubleClick, TripleClick, QuadrupleClick}:
        queueEvent(input.Event(
          kind: KeyUpEvent,
          key: translateKey(button),
          mods: currentMods(),
        ))
    appWindow.onRune = proc(rune: Rune) =
      queueTextEvent(rune.toUTF8())
    windyInitialized = true

  let size = appWindow.logicalSize()
  layout.width = size.x.round().int
  layout.height = size.y.round().int
  # FigDraw already rasterizes at `contentScale`, fractional values included,
  # so the app draws in logical units and enlarges nothing. `scaleX/scaleY` are
  # the rounded report of that; `uiScale` is what an app acts on.
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
  renderQueuedOps()

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
  let slot = getFontSlot(f)
  if not slot.isNil:
    slot.pixieFont = nil

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

proc figSetCursor(c: screen.CursorKind) =
  if appWindow.isNil:
    return
  appWindow.cursor = Cursor(kind: case c
    of curDefault, curArrow: ArrowCursor
    of curIbeam: IBeamCursor
    of curWait: WaitCursor
    of curCrosshair: CrosshairCursor
    of curHand: PointerCursor
    of curSizeNS: ResizeUpDownCursor
    of curSizeWE: ResizeLeftRightCursor)

proc figSetWindowTitle(title: string) =
  if not appWindow.isNil:
    appWindow.title = title

proc figGetClipboardText(): string =
  if TextContent in getClipboardContentKinds(): getClipboardString()
  else: ""

proc figPutClipboardText(text: string) =
  setClipboardString(text)

proc pumpWindowStep() =
  pollEvents()

proc figGetTicks(): int =
  inMilliseconds(getMonoTime() - ticksStart).int

proc figPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  discard flags
  if eventQueue.len == 0:
    pumpWindowStep()
  if eventQueue.len == 0:
    return false
  e = eventQueue.popFirst()
  true

proc figWaitEvent(e: var input.Event; timeoutMs: int; flags: set[InputFlag]): bool =
  discard flags
  let deadlineMs =
    if timeoutMs < 0: int.high
    else: figGetTicks() + timeoutMs
  while eventQueue.len == 0:
    pumpWindowStep()
    if timeoutMs >= 0 and figGetTicks() >= deadlineMs:
      return false
    if timeoutMs >= 0:
      os.sleep(1)
  e = eventQueue.popFirst()
  true

proc figDelay(ms: int) =
  let deadline = figGetTicks() + max(ms, 0)
  while figGetTicks() < deadline:
    pumpWindowStep()
    os.sleep(min(1, deadline - figGetTicks()))

proc figShutdown() =
  if not appWindow.isNil:
    close(appWindow)
  appWindow = nil
  renderer = nil
  eventQueue.clear()
  drawOps.setLen(0)
  stateStack.setLen(0)
  fontSlots.setLen(0)
  images.setLen(0)
  typefaceIdsByPath.clear()
  currentState = DrawState()
  windyInitialized = false

proc initFigDrawWindyDriver*() =
  windowRelays = WindowRelays(
    createWindow: figCreateWindow,
    getWindowLayout: figGetWindowLayout,
    refresh: figRefresh,
    saveState: figSaveState,
    restoreState: figRestoreState,
    setClipRect: figSetClipRect,
    setCursor: figSetCursor,
    setWindowTitle: figSetWindowTitle,
    setWindowClass: proc (instance, className: string) = discard,
    setWindowIcon: proc (cardinals: pointer; n: int) = discard,
  )
  fontRelays = FontRelays(
    openFont: figOpenFont,
    closeFont: figCloseFont,
    getFontMetrics: figGetFontMetrics,
    measureText: figMeasureText,
    drawText: figDrawText,
  )
  drawRelays = DrawRelays(
    fillRect: figFillRect,
    drawLine: figDrawLine,
    drawPoint: figDrawPoint,
    loadImage: figLoadImage,
    freeImage: figFreeImage,
    drawImage: figDrawImage,
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

