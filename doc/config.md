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
    (bg "1E1E2E")
    (fg "CDD6F4"
      (Keyword "CBA6F7")
      (Comment "6C7086"))))
```

```nim
import widgets/config

let c = parseConfig(text)          # or parseConfig(text, myFallbackTheme)
if c.error.len > 0: echo c.error   # nothing in here can be used
if c.note.len > 0: echo c.note     # the theme was refused; c.theme is the fallback

let cells = c.layout.resolve(width, height, lineHeight = fm.lineHeight, gap = 2)
fillRect(cells["sidebar"], c.theme.bg)
editor.theme = c.theme
```

Both parts are optional and may come in either order. A file with no
`(theme ...)` keeps the fallback theme -- `defaultTheme()` unless `parseConfig`
was given another -- and a file with no `(layout ...)` resolves
to no cells.

Nothing here raises. A file that does not parse has its reason in `error` --
`"1:19: the size has to come before the children"` -- and hands back no cells
and the fallback theme, so a program that forgets to look gets an empty window
rather than a half-applied one. That matters for a config a user types: the
editor example puts `error` straight into its status bar and keeps drawing the
last good config.

The layout half can also be read on its own, without the umbrella, which is
what the smaller examples do:

```nim
import uirelays/layout
let l = parseLayout("(layout (editor) (status (lines 1)))")
doAssert l.error.len == 0, l.error
```

# The layout

## Boxes

| Tag | Meaning |
|-----|---------|
| `(layout ...)` | The window. Its children are stacked top to bottom. Only allowed as the outermost tag. |
| `(rows ...)` | Children stacked top to bottom. |
| `(cols ...)` | Children placed left to right. |
| `(anything-else ...)` | A leaf, named by its own tag: `resolve` files its `Rect` under `"anything-else"`. |

There is no `(cell ...)` wrapper because there would be nothing to put in it:
every leaf stands for a concrete widget, so the tag can be the name. That
makes `layout`, `rows`, `cols`, `px`, `lines` and `stretch` the only names a
widget cannot have.

`rows` and `cols` nest in each other, which is all the structure there is --
there is no separate concept for a row that happens to contain a stack:

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
resolving -- the editor example refuses a layout without an `editor` cell,
since that is where the layout itself gets typed.

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
them, which is how the editor example draws its borders. Gaps come off the
stretching boxes, never off a `px` or `lines` one.

# The theme

The tags inside `(theme ...)` are the field names of `Theme` and the tags
inside `(fg ...)` are the values of `TokenClass`, both spelled exactly as they
appear in `widgets/theme.nim`. There is nothing to look up and nothing that
can fall out of sync when a field is added.

```
(theme
  (bg "1E1E2E")
  (fg "CDD6F4"             # the base color of every token class ...
    (Keyword "CBA6F7")     # ... and the ones that differ
    (StringLit "A6E3A1")
    (Comment "6C7086"))
  (selBg "585B70"))
```

A color is the six hex digits of `RRGGBB` in a string literal, in either case
-- what a palette hands you, without the `#`, which would start a comment out
here. There is one way to write a color and no other.

| Tag | What it colors |
|-----|----------------|
| `(fg base? (Class "RRGGBB")*)` | text, per token class; the leading color is all of them at once |
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

## Readability

A theme whose text cannot be seen would hide the very file that has to be
corrected, so `parseConfig` refuses one:

```
too low contrast between colors, used default settings instead -- Comment text is 1.4:1 against the background
```

That arrives in `note`, not `error`: the layout is applied as usual and
`theme` is the fallback. The measure is the WCAG contrast ratio -- computed in
integers, squaring the channels in place of the sRGB curve, which puts black
on white at the textbook 21.0:1 -- and the bar is `MinContrast`, 3.0:1.

WCAG asks 4.5:1 for body text, but `goldenDusk` -- the default theme -- draws
its comments at 4.4:1 and `catppuccinMocha` at 3.8:1, so both would fail their
own test; dim comments are a deliberate and widespread choice. 3.0 is WCAG's
bar for large text and interface parts, and it still catches everything that
genuinely cannot be read.

Only foregrounds are checked, each against `bg`: every token class, the
cursor, the line numbers and the `(x)` button. `selBg`, `activeLineBg`,
`markerBg` and `bracketBg` sit *behind* text and are meant to stay close to
`bg`, and the scrollbar and `actionColor` are hints rather than text -- the
default theme draws its action frame at 1.9:1 on purpose. `contrast` and
`contrastProblem` in `widgets/theme.nim` are public, so an app can hold its
own colors to the same bar.

# Comments

`#` starts a comment that runs to the end of the line, anywhere in the file.
Plain NIF has none, but a config a human edits does need them.

# tinynif

`uirelays/tinynif` is the lexer underneath, and it depends on nothing at
all. It hands out tokens; giving them meaning is the caller's job. In
particular tags stay `string`s, because only the caller knows its own
vocabulary -- `layout.nim` maps them to a `LayoutTag` enum in one `case`
statement.

Parsing is done by keeping the current token in a variable, which is enough
lookahead for recursive descent:

```nim
import uirelays/tinynif

var lex = initLexer(src)
var tok = next(lex)
while tok.kind != tkParRi and tok.kind != tkEof:
  echo tok.position, ": ", $tok
  tok = next(lex)
```

| Kind | `text` | `intVal` |
|------|--------|----------|
| `tkParLe` | the tag directly behind the `(` | |
| `tkParRi` | | |
| `tkDot` | | a lone `.`: the empty node |
| `tkIdent` | the name | |
| `tkSymbol` | a name with a dot in it, `foo.3.mymod` | |
| `tkSymbolDef` | the same, introduced by a `:` | |
| `tkIntLit` | | the value, decimal or `0x` hex |
| `tkCharLit` | | the byte |
| `tkStringLit` | the value, escapes resolved | |
| `tkError` | why the input is malformed | |
| `tkEof` | | |

Every token carries a 1-based `line` and `col`; `position` formats them as
`"line:col"` for the front of a message. Malformed input is a `tkError`
token rather than an exception, and the end of the input keeps returning
`tkEof`, so a parser can check for trouble whenever it is convenient.

NIF escapes are a backslash and exactly two hex digits: a newline in a
string is `\0A`, a backslash `\5C`. There are deliberately no floating
point literals -- `1.5` is reported as an error rather than truncated --
and NIF's own line information prefixes, which generated files carry, are
not understood. This lexer is for the files a program and a person write
between them.
