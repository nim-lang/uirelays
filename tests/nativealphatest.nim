## Exercise actual native composition, not a mock relay.
## Linux: xvfb-run nim r tests/nativealphatest.nim.
when defined(windows):
  include ../src/uirelays/drivers/winapi_driver

  proc GetPixel(dc: HDC, x, y: int32): COLORREF {.stdcall, dynlib: "gdi32", importc.}

  proc prepare() =
    initWinapiDriver()
    gBackDC = CreateCompatibleDC(nil)
    doAssert gBackDC != nil
    var info = BITMAPINFO()
    info.bmiHeader = BITMAPINFOHEADER(
      biSize: DWORD(sizeof(BITMAPINFOHEADER)),
      biWidth: 4,
      biHeight: -3,
      biPlanes: 1,
      biBitCount: 32,
      biCompression: BI_RGB,
    )
    var data: pointer
    gBackBmp = CreateDIBSection(gBackDC, addr info, DIB_RGB_COLORS, addr data, nil, 0)
    doAssert gBackBmp != nil
    gOldBmp = SelectObject(gBackDC, cast[HGDIOBJ](gBackBmp))

  proc pixel(x, y: int): uint32 =
    let c = GetPixel(gBackDC, x.int32, y.int32)
    ((c and 255) shl 16) or (c and 0xff00) or ((c shr 16) and 255)

elif defined(linux):
  include ../src/uirelays/drivers/x11_driver

  proc prepare() =
    initX11Driver()
    discard screen.createWindow(4, 3)

  proc pixel(x, y: int): uint32 =
    let image =
      XGetImage(gDisplay, gBackPixmap, x.cint, y.cint, 1, 1, culong.high, ZPixmap)
    doAssert image != nil and image.bitsPerPixel == 32
    result = cast[ptr uint32](image.data)[] and 0xffffff
    discard XFree(image.data)
    image.data = nil
    discard XFree(cast[pointer](image))

else:
  {.error: "Native alpha tests support Windows and X11".}

proc clear() =
  screen.fillRect(coords.rect(0, 0, 4, 3), screen.color(0, 0, 255))

proc main() =
  prepare()
  clear()
  screen.fillRect(coords.rect(0, 0, 3, 2), screen.color(255, 0, 0, 128))
  doAssert pixel(0, 0) == 0x80007f
  doAssert pixel(2, 1) == 0x80007f
  doAssert pixel(3, 0) == 0x0000ff
  screen.fillRect(coords.rect(0, 0, 3, 2), screen.color(0, 255, 0, 0))
  doAssert pixel(0, 0) == 0x80007f
  clear()
  screen.saveState()
  screen.setClipRect(coords.rect(1, 0, 1, 1))
  screen.fillRect(coords.rect(0, 0, 3, 2), screen.color(255, 0, 0, 128))
  screen.restoreState()
  doAssert pixel(0, 0) == 0x0000ff
  doAssert pixel(1, 0) == 0x80007f
  doAssert pixel(1, 1) == 0x0000ff
  clear()
  var pixels = [0x80800000'u32, 0x00000000'u32, 0x80008000'u32, 0xffffffff'u32]
  let data = cast[ptr UncheckedArray[uint32]](addr pixels[0])
  doAssert screen.drawRGBA(
    data, 2, 2, coords.rect(0, 0, 2, 2), RGBAFormat.argbPremultiplied
  )
  doAssert pixel(0, 0) == 0x80007f
  doAssert pixel(1, 0) == 0x0000ff
  doAssert pixel(0, 1) == 0x00807f
  doAssert pixel(1, 1) == 0xffffff
  doAssert pixels == [0x80800000'u32, 0x00000000'u32, 0x80008000'u32, 0xffffffff'u32]

  clear()
  doAssert screen.blitRGBA(
    data, 2, 2, coords.rect(0, 0, 1, 2), RGBAFormat.argbPremultiplied
  )
  doAssert pixel(0, 0) == 0x80007f
  doAssert pixel(0, 1) == 0x00807f
  doAssert pixel(1, 0) == 0x0000ff
  doAssert pixel(1, 1) == 0x0000ff

  clear()
  screen.saveState()
  screen.setClipRect(coords.rect(1, 0, 1, 1))
  doAssert screen.drawRGBA(
    data, 1, 1, coords.rect(0, 0, 3, 2), RGBAFormat.argbPremultiplied
  )
  screen.restoreState()
  doAssert pixel(0, 0) == 0x0000ff
  doAssert pixel(1, 0) == 0x80007f
  doAssert pixel(2, 0) == 0x0000ff
  doAssert pixel(1, 1) == 0x0000ff

  clear()
  # Top-byte zero keeps its historic opaque meaning unless alpha is requested.
  pixels[0] = 0x00ff0000
  doAssert screen.drawRGBA(data, 1, 1, coords.rect(0, 0, 1, 1))
  doAssert pixel(0, 0) == 0xff0000
  echo "Native alpha composition passed"

main()
