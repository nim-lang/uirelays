## Siwin windows/events with platform-native composition. No FigDraw/GPU renderer.
import std/[deques, math, monotimes, os, times, unicode]
import siwin
import siwin/platforms/any/clipboards
import vmath
import ../[coords, input, screen, waitinterrupt]
import ./siwin_keys

when defined(macosx):
  import ./cocoa_driver as platformNative
elif defined(windows):
  import std/importutils
  import siwin/platforms/winapi/window as winWindow
  import ./winapi_driver as platformNative
  privateAccess winWindow.WindowWinapiSoftwareRendering
  privateAccess typeof(default(winWindow.WindowWinapiSoftwareRendering).buffer)
elif defined(linux) or defined(bsd):
  import siwin/platforms/x11/window as xWindow
  import ./x11_driver as platformNative
else:
  {.error: "Native Siwin composition supports Cocoa, WinAPI, and X11".}

var
  appWindow: siwin.Window
  appGlobals: SiwinGlobals
  appWaker: EventLoopWaker  ## thread-safe handle to appGlobals' loop
  events: Deque[input.Event]
  presenting: bool
  ticksStart = getMonoTime()

proc density(): float32 =
  if appWindow.isNil:
    return 1
  result = appWindow.uiScale()
  if result <= 0 or classify(result) in {fcNan, fcInf, fcNegInf}:
    result = 1

proc currentLayout(): ScreenLayout =
  if appWindow.isNil:
    return ScreenLayout(scaleX: 1, scaleY: 1, uiScale: 100)
  let size = appWindow.size
  when defined(macosx):
    let scale = density()
    ScreenLayout(
      width: round(size.x.float32 / scale).int,
      height: round(size.y.float32 / scale).int,
      scaleX: max(1, round(scale).int),
      scaleY: max(1, round(scale).int),
      uiScale: 100,
    )
  else:
    ScreenLayout(
      width: size.x.int,
      height: size.y.int,
      scaleX: 1,
      scaleY: 1,
      uiScale: round(density() * 100).int,
    )

proc coordinate(value: float32): int =
  when defined(macosx):
    round(value / density()).int
  else:
    round(value).int

proc bindSurface() =
  if appWindow.isNil or appWindow.closed:
    return
  when defined(macosx):
    let buffer = appWindow.pixelBuffer()
    if buffer.data != nil and buffer.size.x > 0 and buffer.size.y > 0:
      if platformNative.prepareSiwinSurface(
        buffer.size.x.cint, buffer.size.y.cint, density().cdouble
      ) == 0:
        raise
          newException(ValueError, "Cannot create the Core Graphics drawing surface")
  elif defined(windows):
    let window = winWindow.WindowWinapiSoftwareRendering(appWindow)
    let buffer = window.pixelBuffer()
    platformNative.attachSiwinSurface(
      cast[pointer](window.buffer.hdc), buffer.size.x.int, buffer.size.y.int
    )
  else:
    let window = xWindow.WindowX11SoftwareRendering(appWindow)
    let size = window.size
    if size.x > 0 and size.y > 0:
      platformNative.attachSiwinSurface(
        window.nativeDisplayHandle(),
        window.nativeWindowHandle(),
        size.x.int,
        size.y.int,
      )

proc render(event: RenderEvent) =
  bindSurface()
  when defined(macosx):
    let buffer = appWindow.pixelBuffer()
    if buffer.data != nil:
      if platformNative.presentSiwinSurface(
        buffer.data, buffer.size.x.cint, buffer.size.y.cint
      ) == 0:
        raise newException(ValueError, "Cannot present the native drawing surface")
  elif defined(windows):
    let window = winWindow.WindowWinapiSoftwareRendering(appWindow)
    if not platformNative.presentSiwinSurface(cast[pointer](window.buffer.hdc)):
      raise newException(ValueError, "Cannot present the native GDI drawing surface")
  elif defined(linux) or defined(bsd):
    platformNative.presentSiwinSurface()
  if not presenting:
    events.addLast(input.Event(kind: NoEvent))

proc resized(event: ResizeEvent) =
  let current = currentLayout()
  events.addLast(
    input.Event(
      kind: WindowMetricsEvent,
      x: current.width,
      y: current.height,
      scaleX: current.scaleX,
      scaleY: current.scaleY,
      uiScale: current.uiScale,
    )
  )

proc create(layout: var ScreenLayout, icon: pointer, iconLen: int) =
  if not appWindow.isNil:
    raise newException(ValueError, "The Siwin driver already has a window")
  when defined(linux) or defined(bsd):
    # uirelays' native Unix drawing is Xft/XRender; Wayland sessions use XWayland.
    appGlobals = newSiwinGlobals(Platform.x11)
  else:
    appGlobals = newSiwinGlobals()
  appWaker = appGlobals.eventLoopWaker()
  appWindow = appGlobals.newSoftwareRenderingWindow(
    size = ivec2(max(layout.width, 1).int32, max(layout.height, 1).int32),
    title = "uirelays",
    fullscreen = layout.fullScreen,
  )
  when defined(linux) or defined(bsd):
    xWindow.WindowX11SoftwareRendering(appWindow).softwarePresentEnabled = false
  appWindow.eventsHandler = WindowEventsHandler(
    onRender: render,
    onResize: resized,
    onClose: proc(event: CloseEvent) =
      events.addLast(input.Event(kind: WindowCloseEvent)),
    onStateBoolChanged: proc(event: StateBoolChangedEvent) =
      if event.kind == siwin.StateBoolChangedEventKind.focus:
        events.addLast(
          input.Event(
            kind: if event.value: WindowFocusGainedEvent else: WindowFocusLostEvent
          )
        )
    ,
    onKey: proc(event: KeyEvent) =
      events.addLast(
        input.Event(
          kind: if event.pressed: KeyDownEvent else: KeyUpEvent,
          key: translateKey(event.key),
          mods: translateMods(event.modifiers),
        )
      ),
    onTextInput: proc(event: siwin.TextInputEvent) =
      for rune in event.text.runes:
        let text = rune.toUTF8()
        var translated = input.Event(kind: TextInputEvent)
        for i in 0 ..< min(4, text.len):
          translated.text[i] = text[i]
        events.addLast(translated),
    onMouseMove: proc(event: siwin.MouseMoveEvent) =
      events.addLast(
        input.Event(
          kind: MouseMoveEvent, x: coordinate(event.pos.x), y: coordinate(event.pos.y)
        )
      ),
    onMouseButton: proc(event: siwin.MouseButtonEvent) =
      events.addLast(
        input.Event(
          kind: if event.pressed: MouseDownEvent else: MouseUpEvent,
          x: coordinate(event.window.mouse.pos.x),
          y: coordinate(event.window.mouse.pos.y),
          button: translateButton(event.button),
          clicks: 1,
        )
      ),
    onScroll: proc(event: siwin.ScrollEvent) =
      events.addLast(
        input.Event(
          kind: MouseWheelEvent, x: round(event.deltaX).int, y: round(event.delta).int
        )
      ),
    onClick: proc(event: siwin.ClickEvent) =
      if events.len > 0:
        var previous = events.popLast()
        if previous.kind in {MouseDownEvent, MouseUpEvent}:
          previous.clicks = if event.double: 2 else: 1
        events.addLast(previous)
    ,
  )
  appWindow.firstStep()
  appWindow.redraw()
  appWindow.serviceWindow()
  bindSurface()
  layout = currentLayout()

proc refresh() =
  if appWindow.isNil or appWindow.closed:
    return
  presenting = true
  try:
    appWindow.redraw()
    appWindow.serviceWindow()
  finally:
    presenting = false

proc poll(event: var input.Event, flags: set[InputFlag]): bool =
  if events.len == 0 and not appWindow.isNil and appWindow.opened:
    discard appGlobals.pollEvents()
    appWindow.serviceWindow()
    bindSurface()
  if events.len == 0:
    return false
  event = events.popFirst()
  true

proc wait(event: var input.Event, timeoutMs: int, flags: set[InputFlag]): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = max(timeoutMs, 0))
  if poll(event, flags):
    return true
  if takeInterrupt():
    return false
  while not appWindow.isNil and appWindow.opened:
    let remaining =
      if timeoutMs < 0:
        Duration.high
      else:
        deadline - getMonoTime()
    if timeoutMs >= 0 and remaining.inNanoseconds <= 0:
      return false
    let activity = appGlobals.waitEvents(remaining)
    if appWindow.opened:
      appWindow.serviceWindow()
      bindSurface()
    if events.len > 0:
      event = events.popFirst()
      return true
    if takeInterrupt() or activity == eventTimeout:
      return false
  false

proc interruptWait() {.gcsafe.} =
  # The waker stays valid (and harmless) after the loop shuts down; it must
  # not be called while createWindow replaces it.
  if raiseInterrupt():
    {.cast(gcsafe).}:
      appWaker.wake()

proc shutdown() =
  platformNative.detachSiwinSurface()
  if not appWindow.isNil:
    appWindow.eventsHandler = WindowEventsHandler()
    if appWindow.opened:
      appWindow.close()
  appWindow = nil
  appGlobals = nil
  events.clear()

proc setCursor(cursor: screen.CursorKind) =
  if appWindow.isNil:
    return
  appWindow.cursor = siwin.Cursor(
    kind: siwin.CursorKind.builtin,
    builtin:
      case cursor
      of curDefault, curArrow: BuiltinCursor.arrow
      of curIbeam: BuiltinCursor.text
      of curWait: BuiltinCursor.wait
      of curCrosshair: BuiltinCursor.cross
      of curHand: BuiltinCursor.pointingHand
      of curSizeNS: BuiltinCursor.sizeVertical
      of curSizeWE: BuiltinCursor.sizeHorizontal
    ,
  )

proc initSiwinDriver*() =
  when defined(macosx):
    platformNative.initCocoaDriver()
  elif defined(windows):
    platformNative.initWinapiDriver()
  else:
    platformNative.initX11Driver()
  windowRelays.createWindow = create
  windowRelays.getWindowLayout = currentLayout
  windowRelays.refresh = refresh
  windowRelays.setCursor = setCursor
  windowRelays.setWindowTitle = proc(title: string) =
    if not appWindow.isNil:
      appWindow.title = title
  inputRelays = InputRelays(
    pollEvent: poll,
    waitEvent: wait,
    interruptWaitEvent: interruptWait,
    getTicks: proc(): int =
      (getMonoTime() - ticksStart).inMilliseconds.int,
    sleep: proc(ms: int) =
      os.sleep(ms),
    shutdown: shutdown,
  )
  clipboardRelays = ClipboardRelays(
    getText: proc(): string =
      if appWindow.isNil: "" else: appWindow.clipboard.text,
    putText: proc(text: string) =
      if not appWindow.isNil:
        appWindow.clipboard.text = text
    ,
  )
