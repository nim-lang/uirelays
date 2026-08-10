# The config file

One NIF file says where a window's widgets go and what they look like:

```
(config
  (layout
    (toolbar (lines 2))
    (cols
      (sidebar (px 250))
      (divider (px 4))
      (editor))
    (status (lines 1)))
  (theme
    (bg "#15171B")
    (fg "#E6DFD1"
      (Keyword "#E5B94E")
      (Comment "#7A7365"))))
```

# The layout

## Boxes

| Tag | Meaning |
|-----|---------|
| `(layout ...)` | The window. Its children are stacked top to bottom. Only allowed as the outermost tag. |
| `(rows ...)` | Children stacked top to bottom. |
| `(cols ...)` | Children placed left to right. |
| `(anything-else ...)` | A leaf, named by its own tag. |

`rows` and `cols` nest in each other.

```
(layout
  (cols
    (rows (px 200)      # a 200px wide column ...
      (tabs (lines 6))  # ... with two widgets in it
      (explorer))
    (editor (stretch 3))))
```

A misspelled `cols` therefore reads as a widget name, and the message says so,
pointing at the child that cannot be there:

```
3:10: 'col' names a widget, and a widget has no children; did you mean (rows ...) or (cols ...)?
```

The other side of that coin: a misspelled *widget* name is a perfectly good
layout for a widget nobody draws. Check for the cells you need after
resolving -- focim refuses a layout without an `editor` cell, since that is
where the layout itself gets typed.

## Sizes

A box may state its size along the axis its parent divides: a height inside
`rows`, a width inside `cols`. The outermost `(layout ...)` divides
vertically, so its children state heights.

| Size | Meaning |
|------|---------|
| `(px 250)` | 250 of whatever unit the driver draws in. |
| `(lines 5)` | `5 * lineHeight`, plus `padding` above and below. |
| `(stretch 2)` | Two shares of what the fixed sizes leave over. |

Leaving the size out means `(stretch 1)`, so `(editor)` fills what is
left. When a size is given it has to come before the children, so that it
cannot hide in the middle of a long list.

`resolve` hands the last stretching child the remainder of the division, so
children always fill their parent exactly instead of leaving a one pixel
seam: three `(stretch 1)` boxes in 100 pixels are 33, 33 and 34.

`gap` inserts pixels between adjacent boxes -- the background shows through
them, which is how focim draws its borders. Gaps come off the
stretching boxes, never off a `px` or `lines` one.

# The theme

The tags inside `(theme ...)` are the field names of `Theme` and the tags
inside `(fg ...)` are the values of `TokenClass`, both spelled exactly as they
appear in `widgets/theme.nim`. There is nothing to look up and nothing that
can fall out of sync when a field is added.

```
(theme
  (bg "#15171B")
  (fg "#E6DFD1"            # the base color of every token class ...
    (Keyword "#E5B94E")    # ... and the ones that differ
    (StringLit "#2EC4B6")
    (Comment "#7A7365"))
  (selBg "#35474B"))
```

A color is `"#RRGGBB"` in a string literal.

| Tag | What it colors |
|-----|----------------|
| `(fg base? (Class "#RRGGBB")*)` | text, per token class; the leading color is all of them at once |
| `(bg ...)` | the editor background |
| `(selBg ...)` | selection background |
| `(bracketBg ...)` | the matching bracket |
| `(cursorColor ...)` | the caret |
| `(lineNumColor ...)` | line numbers |
| `(markerBg ...)` | marker highlight, e.g. search hits |
| `(scrollBarColor ...)` | the scrollbar grip |
| `(scrollBarActiveColor ...)` | the grip while dragging |
| `(scrollTrackColor ...)` | the scrollbar track |
| `(activeLineBg ...)` | the line the cursor is on |
| `(actionColor ...)` | the frame around a line that acts on click |
| `(closeColor ...)` | the `(x)` on such a line |

Anything left out keeps the value it has in the fallback theme, so a config
can change one color without restating the palette.

