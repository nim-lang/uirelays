## Opaque RGB image resampling for drivers without native image scaling.
import std/math

proc resizedRGBA*(
    pixels: ptr UncheckedArray[uint32], width, height, outputWidth, outputHeight: int
): seq[uint32] =
  ## Returns tightly packed 0x00RRGGBB pixels with bilinear resampling.
  ## HiDPI callers normally match destination device dimensions and avoid
  ## this path entirely; X11 uses it when an image actually changes size.
  if pixels == nil or min(min(width, height), min(outputWidth, outputHeight)) <= 0:
    raise newException(ValueError, "Image dimensions and data must be valid")
  result = newSeq[uint32](outputWidth * outputHeight)
  for y in 0 ..< outputHeight:
    let
      sy = clamp(
        (y.float64 + 0.5) * height.float64 / outputHeight.float64 - 0.5,
        0.0,
        (height - 1).float64,
      )
      y0 = floor(sy).int
      y1 = min(y0 + 1, height - 1)
      fy = sy - y0.float64
    for x in 0 ..< outputWidth:
      let
        sx = clamp(
          (x.float64 + 0.5) * width.float64 / outputWidth.float64 - 0.5,
          0.0,
          (width - 1).float64,
        )
        x0 = floor(sx).int
        x1 = min(x0 + 1, width - 1)
        fx = sx - x0.float64
      var pixel: uint32
      for shift in [0, 8, 16]:
        let
          a = ((pixels[y0 * width + x0] shr shift) and 255).float64
          b = ((pixels[y0 * width + x1] shr shift) and 255).float64
          c = ((pixels[y1 * width + x0] shr shift) and 255).float64
          d = ((pixels[y1 * width + x1] shr shift) and 255).float64
          top = a * (1 - fx) + b * fx
          bottom = c * (1 - fx) + d * fx
        pixel = pixel or (round(top * (1 - fy) + bottom * fy).uint32 shl shift)
      result[y * outputWidth + x] = pixel
