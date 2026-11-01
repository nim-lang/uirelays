## Headless tests of the actual GTK driver drawing callbacks.
## Requires GTK4 development headers; no window/display is initialized.
include ../src/uirelays/drivers/gtk4_driver

proc pixel(x, y: int): uint32 =
  cairo_surface_flush(backingSurf)
  let data = cast[ptr UncheckedArray[uint32]](cairo_image_surface_get_data(backingSurf))
  data[y * (cairo_image_surface_get_stride(backingSurf).int div 4) + x] and 0xffffff

proc main() =
  initGtk4Driver()
  # Calls before a window has a backing context remain harmless.
  screen.saveState()
  screen.restoreState()
  backingSurf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 4, 3)
  doAssert backingSurf != nil
  defer:
    cairo_surface_destroy(backingSurf)
    backingSurf = nil
  backingCr = cairo_create(backingSurf)
  doAssert backingCr != nil
  defer:
    cairo_destroy(backingCr)
    backingCr = nil

  screen.fillRect(rect(0, 0, 4, 3), screen.color(0, 0, 255))
  screen.saveState()
  screen.setClipRect(rect(1, 0, 1, 1))
  screen.fillRect(rect(0, 0, 4, 3), screen.color(255, 0, 0))
  screen.restoreState()
  screen.fillRect(rect(0, 1, 4, 1), screen.color(0, 255, 0))
  for y in 0 ..< 3:
    for x in 0 ..< 4:
      let expected =
        if y == 1:
          0x00ff00'u32
        elif x == 1 and y == 0:
          0xff0000'u32
        else:
          0x0000ff'u32
      doAssert pixel(x, y) == expected

  screen.fillRect(rect(0, 0, 4, 3), screen.color(0, 0, 255))
  screen.saveState()
  screen.setClipRect(rect(0, 0, 2, 3))
  screen.saveState()
  screen.setClipRect(rect(0, 0, 1, 3))
  screen.fillRect(rect(0, 0, 4, 1), screen.color(255, 0, 0))
  screen.restoreState()
  screen.fillRect(rect(0, 1, 4, 1), screen.color(0, 255, 0))
  screen.restoreState()
  screen.fillRect(rect(0, 2, 4, 1), screen.color(255, 255, 255))
  for x in 0 ..< 4:
    doAssert pixel(x, 0) == (if x == 0: 0xff0000'u32 else: 0x0000ff'u32)
    doAssert pixel(x, 1) == (if x < 2: 0x00ff00'u32 else: 0x0000ff'u32)
    doAssert pixel(x, 2) == 0xffffff'u32
  echo "GTK drawing state tests passed"

main()
