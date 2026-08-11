# Platform-independent input events and relays.
# Part of the core stdlib abstraction.

type
  KeyCode* = enum
    KeyNone,
    KeyA, KeyB, KeyC, KeyD, KeyE, KeyF, KeyG, KeyH, KeyI, KeyJ,
    KeyK, KeyL, KeyM, KeyN, KeyO, KeyP, KeyQ, KeyR, KeyS, KeyT,
    KeyU, KeyV, KeyW, KeyX, KeyY, KeyZ,
    Key0, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9,
    KeyF1, KeyF2, KeyF3, KeyF4, KeyF5, KeyF6,
    KeyF7, KeyF8, KeyF9, KeyF10, KeyF11, KeyF12,
    KeyEnter, KeySpace, KeyEsc, KeyTab,
    KeyBackspace, KeyDelete, KeyInsert,
    KeyLeft, KeyRight, KeyUp, KeyDown,
    KeyPageUp, KeyPageDown, KeyHome, KeyEnd,
    KeyCapslock, KeyComma, KeyPeriod, KeySlash,
    KeyMinus, KeyEqual, KeyPlus

  EventKind* = enum
    NoEvent,
    KeyDownEvent, KeyUpEvent, TextInputEvent,
    MouseDownEvent, MouseUpEvent, MouseMoveEvent, MouseWheelEvent,
    WindowResizeEvent, WindowMetricsEvent, WindowCloseEvent,
    WindowFocusGainedEvent, WindowFocusLostEvent,
    QuitEvent

  Modifier* = enum
    ShiftPressed, CtrlPressed, AltPressed, GuiPressed

  MouseButton* = enum
    LeftButton, RightButton, MiddleButton

  InputFlag* = enum
    WantTextInput   ## show on-screen keyboard / enable IME

  Event* = object
    kind*: EventKind
    key*: KeyCode
    mods*: set[Modifier]
    text*: array[4, char]  ## TextInputEvent: one UTF-8 codepoint, no alloc
    x*, y*: int            ## mouse position, scroll delta, or new window size
    scaleX*, scaleY*: int  ## WindowMetricsEvent: device pixels per coordinate
                           ## unit, as in `ScreenLayout`
    uiScale*: int          ## WindowMetricsEvent: percent to enlarge the UI by,
                           ## as in `ScreenLayout`. A change here means the
                           ## window moved to a display of another density.
    button*: MouseButton   ## MouseDownEvent/MouseUpEvent: which button
    clicks*: int           ## number of consecutive clicks (double-click = 2)

  ClipboardRelays* = object
    getText*: proc (): string {.nimcall.}
    putText*: proc (text: string) {.nimcall.}

  InputRelays* = object
    pollEvent*: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
    waitEvent*: proc (e: var Event; timeoutMs: int;
                      flags: set[InputFlag]): bool {.nimcall.}
    getTicks*: proc (): int {.nimcall.}
    sleep*: proc (ms: int) {.nimcall.}
    shutdown*: proc () {.nimcall.}

var clipboardRelays* = ClipboardRelays(
  getText: proc (): string = "",
  putText: proc (text: string) = discard)

var inputRelays* = InputRelays(
  pollEvent: proc (e: var Event; flags: set[InputFlag]): bool = false,
  waitEvent: proc (e: var Event; timeoutMs: int;
                   flags: set[InputFlag]): bool = false,
  getTicks: proc (): int = 0,
  sleep: proc (ms: int) = discard,
  shutdown: proc () = discard)

proc foldCommandIntoCtrl(e: var Event) =
  ## On macOS the Command key plays the role Control plays everywhere else:
  ## Cmd+S saves, Cmd+C copies, Cmd+Z undoes. So it is folded into
  ## `CtrlPressed` here, at the one point every event passes through, and
  ## every `CtrlPressed in e.mods` in every widget and app keeps working
  ## unchanged -- no call site has to remember to spell out
  ## `or GuiPressed in e.mods`, and none of them can forget to.
  ##
  ## `GuiPressed` stays set alongside it, so the rare binding that really does
  ## mean "the Command key" can still tell the two apart: SynEdit's
  ## Cmd+click-to-follow-a-link, and `ctrlOnly` below.
  when defined(macosx):
    if GuiPressed in e.mods: e.mods.incl CtrlPressed

proc ctrlOnly*(mods: set[Modifier]): bool =
  ## `CtrlPressed` with the folded Command key taken back out: true only when
  ## the physical Control key is down. For the rare binding that has to stay
  ## distinct from Command -- a terminal's Ctrl+C interrupts a process while
  ## Cmd+C copies, and both have to keep working.
  when defined(macosx): CtrlPressed in mods and GuiPressed notin mods
  else: CtrlPressed in mods

proc pollEvent*(e: var Event; flags: set[InputFlag] = {}): bool =
  result = inputRelays.pollEvent(e, flags)
  if result: foldCommandIntoCtrl(e)
proc waitEvent*(e: var Event; timeoutMs: int = -1;
                flags: set[InputFlag] = {}): bool =
  result = inputRelays.waitEvent(e, timeoutMs, flags)
  if result: foldCommandIntoCtrl(e)
proc getClipboardText*(): string = clipboardRelays.getText()
proc putClipboardText*(text: string) = clipboardRelays.putText(text)
proc getTicks*(): int = inputRelays.getTicks()
proc sleep*(ms: int) = inputRelays.sleep(ms)
proc shutdown*() = inputRelays.shutdown()
