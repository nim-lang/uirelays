#ifndef UIRELAYS_CAIRO_RGBA_H
#define UIRELAYS_CAIRO_RGBA_H

#include <cairo.h>

/* Paint a whole opaque image into a logical destination, preserving its
   edge pixels when Cairo filters a scaled source. */
static inline void uirelays_draw_cairo_rgba(
    cairo_t *cr, cairo_surface_t *source, int width, int height,
    int x, int y, int destinationWidth, int destinationHeight) {
  cairo_save(cr);
  cairo_rectangle(cr, x, y, destinationWidth, destinationHeight);
  cairo_clip(cr);
  cairo_translate(cr, x, y);
  cairo_scale(cr, (double)destinationWidth / width, (double)destinationHeight / height);
  cairo_set_source_surface(cr, source, 0, 0);
  /* EXTEND_NONE introduces transparent samples around an opaque image. */
  cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD);
  cairo_paint(cr);
  cairo_restore(cr);
}

#endif
