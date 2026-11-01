## Text rendered into pixels of its own, by a driver that has no window: the
## way a GPU renderer with a window from elsewhere asks for its glyphs. Run
## with the platform's default driver, and with `-d:gtk4` on Linux.
import uirelays/screen
when defined(windows):
  import std/os
  import uirelays/drivers/winapi_driver
  initWinapiFontRelays()
else:
  import uirelays/backend
  initBackend()

var metrics = FontMetrics()
let font = openFont("", 16, metrics)
doAssert font.int != 0
doAssert metrics.lineHeight > 0

let measured = measureText(font, "Hello, world")
doAssert measured.w > 0 and measured.h > 0

var pixels: seq[uint32]
let fg = Color(r: 200, g: 100, b: 50, a: 255)
let rendered = renderText(font, "Hello, world", fg, pixels)
doAssert rendered == measured
doAssert pixels.len == rendered.w * rendered.h

var inked = 0
for p in pixels:
  let a = p shr 24
  # Premultiplied: no channel is brighter than the pixel is opaque.
  doAssert ((p shr 16) and 0xFF) <= a
  doAssert ((p shr 8) and 0xFF) <= a
  doAssert (p and 0xFF) <= a
  if a > 0: inked.inc
doAssert inked > 0
doAssert inked < pixels.len, "text is drawn on transparency"

for foreground in [Color(r: 255, g: 255, b: 255, a: 255),
                   Color(r: 200, g: 100, b: 50, a: 128)]:
  doAssert renderText(font, "Hello, world", foreground, pixels) == measured
  for p in pixels:
    let a = p shr 24
    doAssert a <= foreground.a.uint32
    doAssert ((p shr 16) and 0xFF) <= a
    doAssert ((p shr 8) and 0xFF) <= a
    doAssert (p and 0xFF) <= a
    if foreground.r == 255:
      doAssert ((p shr 16) and 0xFF) == a
      doAssert ((p shr 8) and 0xFF) == a
      doAssert (p and 0xFF) == a

doAssert renderText(font, "", fg, pixels) == TextExtent()
doAssert pixels.len == 0
closeFont(font)

when defined(windows):
  # The face a file holds is read from the file, not guessed from its name:
  # "segoeuib.ttf" says nothing about being bold.
  let fonts = getEnv("WINDIR", r"C:\Windows") / "Fonts"
  if fileExists(fonts / "segoeui.ttf") and fileExists(fonts / "segoeuib.ttf"):
    let regular = openFont(fonts / "segoeui.ttf", 32, metrics)
    let bold = openFont(fonts / "segoeuib.ttf", 32, metrics)
    doAssert measureText(bold, "Hello, world").w > measureText(regular, "Hello, world").w
    closeFont(regular)
    closeFont(bold)
echo "rendertexttest: OK"

when defined(windows):
  proc getCurrentProcess(): pointer {.stdcall, dynlib: "kernel32", importc: "GetCurrentProcess".}
  proc getGuiResources(process: pointer, flags: uint32): uint32 {.stdcall, dynlib: "user32", importc: "GetGuiResources".}

  # Font-only clients must leave the application's installed relays untouched.
  let installed = fontRelays
  let isolated = winapiFontRelays()
  doAssert fontRelays.openFont == installed.openFont
  let before = getGuiResources(getCurrentProcess(), 0)
  for i in 0 ..< 100:
    var metrics: FontMetrics
    let font = isolated.openFont("", 12 + i mod 12, {}, metrics)
    doAssert font.int != 0
    doAssert isolated.measureText(font, "hello").w > 0
    isolated.closeFont(font)
  doAssert getGuiResources(getCurrentProcess(), 0) <= before + 1

  var invalidMetrics: FontMetrics
  doAssert isolated.openFontFace("", 1, 16, {}, invalidMetrics).int == 0
