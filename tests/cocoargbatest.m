/* clang -fobjc-arc tests/cocoargbatest.m -o /tmp/uirelays-cocoargbatest
   -framework Cocoa -framework CoreText -framework CoreGraphics -framework QuartzCore */
#include <assert.h>
#include "../src/uirelays/drivers/cocoa_backend.m"

int main(void) {
  @autoreleasepool {
    ensureBacking(2, 1, 2.0);
    uint32_t pixels[] = {
      0xff0000, 0x00ff00, 0x0000ff, 0xffffff,
      0x00ffff, 0xff00ff, 0xffff00, 0x000000
    };
    assert(cocoa_drawRGBA(pixels, 4, 2, 0, 0, 2, 1));
    uint32_t *backing = CGBitmapContextGetData(backingCtx);
    /* Each independently colored source pixel survives on a 2x surface. */
    for (int i = 0; i < 8; ++i)
      assert((backing[i] & 0xffffff) == pixels[i]);

    /* Resizing keeps the old content at its original position and size. */
    ensureBacking(3, 2, 2.0);
    backing = CGBitmapContextGetData(backingCtx);
    assert(CGBitmapContextGetWidth(backingCtx) == 6);
    for (int y = 0; y < 2; ++y)
      for (int x = 0; x < 4; ++x)
        assert((backing[y*6+x] & 0xffffff) == pixels[y*4+x]);
    ensureBacking(2, 1, 2.0);
    backing = CGBitmapContextGetData(backingCtx);
    for (int i = 0; i < 8; ++i)
      assert((backing[i] & 0xffffff) == pixels[i]);

    uint32_t legacy[] = {0xff0000, 0x0000ff};
    assert(cocoa_blitRGBA(legacy, 2, 1, 0, 0, 2, 1));
    backing = CGBitmapContextGetData(backingCtx);
    assert((backing[0] & 0xffffff) == 0xff0000);
    assert((backing[3] & 0xffffff) == 0x0000ff);

    /* Moving to a 1x monitor with the same point size reallocates the bitmap. */
    ensureBacking(2, 1, 1.0);
    assert(CGBitmapContextGetWidth(backingCtx) == 2);
    assert(CGBitmapContextGetHeight(backingCtx) == 1);
    CGContextRelease(backingCtx);
    backingCtx = NULL;
  }
  return 0;
}
