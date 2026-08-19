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
| `(px 250)` | 250 *logical* pixels: `resolve`'s `uiScale` turns them into the display's, so the same config gives the same window on a 4K laptop panel as on a 96 dpi monitor. |
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
  (fg "#E6DFD1"                     # the base color of every token class ...
    (Keyword "#E5B94E" (bold))      # ... and the ones that differ
    (StringLit "#2EC4B6")
    (Comment "#7A7365" (italics)))
  (selBg "#35474B"))
```

A color is `"#RRGGBB"` in a string literal.

focim's own config writes every token class out, so a class can be recolored
by editing its line instead of by first finding out that it exists. Delete the
ones you do not care about: what a config leaves unsaid keeps the color it
has.

| Tag | What it colors |
|-----|----------------|
| `(fg base? (Class "#RRGGBB" style*)*)` | text, per token class; the leading color is all of them at once |
| `(bg ...)` | the editor background |
| `(panelBg ...)` | the background of the panels around it: tabs, explorer, terminal, status bar |
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
| `(focusColor ...)` | the frame around the panel the keystrokes go to |

Anything left out keeps the value it has in the fallback theme, so a config
can change one color without restating the palette.

## Bold and italics

A token class may say how its text is cut, behind the color:

```
(fg
  (Keyword "#E5B94E" (bold))
  (Comment "#7A7365" (italics))
  (Directive "#1FA398" (bold) (italics)))
```

| Tag | Meaning |
|-----|---------|
| `(bold)` | the bold face of the same family |
| `(italics)` | the italic face |

Both are wishes. A family without the face -- and a driver that cannot ask for
one -- draws the regular face, so a style can never make text vanish. Nothing
here moves anything: the faces of a monospaced family share its advance width,
so a bold keyword sits on the same grid as the code around it.

A class that names its color also names its style, so a class listed *without*
`(bold)` or `(italics)` is upright, whatever the fallback theme does. The
style tags belong behind a color, inside the class -- `(bold)` on its own
directly under `(fg ...)` is refused, since "all classes bold" is not a thing
anyone means to say.

