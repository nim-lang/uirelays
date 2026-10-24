## Relay contract tests; no window or platform driver is initialized.
import std/unittest
import ../src/uirelays/[screen, coords]

var sourceW, sourceH, calls: int
var destination: Rect

proc draw(pixels: ptr UncheckedArray[uint32], w, h: int, dst: Rect): bool =
  sourceW = w
  sourceH = h
  destination = dst
  inc calls
  true

suite "RGBA image relays":
  setup:
    let saved = drawRelays
    drawRelays.drawRGBA = draw
    drawRelays.blitRGBA = draw
    calls = 0
  teardown:
    drawRelays = saved

  test "full-resolution sources retain their logical destination":
    var pixels = [0xff0000'u32, 0x00ff00'u32, 0x0000ff'u32, 0xffffff'u32]
    check drawRGBA(
      cast[ptr UncheckedArray[uint32]](addr pixels[0]), 4, 1, rect(5, 6, 2, 1)
    )
    check sourceW == 4
    check sourceH == 1
    check destination == rect(5, 6, 2, 1)

  test "legacy relay fallback requires matching dimensions":
    drawRelays.drawRGBA = nil
    var pixels = [0'u32, 0'u32]
    let data = cast[ptr UncheckedArray[uint32]](addr pixels[0])
    check drawRGBA(data, 2, 1, rect(0, 0, 2, 1))
    check calls == 1
    check not drawRGBA(data, 2, 1, rect(0, 0, 1, 1))
    check calls == 1

  test "invalid images do not invoke the driver":
    check not drawRGBA(nil, 1, 1, rect(0, 0, 1, 1))
    check calls == 0
