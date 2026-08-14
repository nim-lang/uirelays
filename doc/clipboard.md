# The clipboard panel

A system clipboard holds one thing. Copy a second thing before pasting the
first and the first is gone -- a mistake everybody makes, and the one edit no
`Ctrl+Z` anywhere can take back, because the text was never in a document.

The `clipboard` cell keeps what the clipboard held: the last 30 texts that
entered it, newest first.

| | |
|---|---|
| `Ctrl+1` .. `Ctrl+9` | paste that row at the caret |
| click a row | the same, and the caret goes back to the editor |
| the `(x)` | forget that row |
| the wheel | scroll, whether the panel has the focus or not |

One `Ctrl+Z` takes a paste back whole, however many lines it was.

## What gets into it

Everything that enters the system clipboard, whichever application put it
there -- including whatever was already on it when the editor started. The
editor is not a special case: its own `Ctrl+C` puts the text on the system
clipboard like anybody else's, and it arrives here by being read back. One
path, not two.

Read means read: the clipboard is looked at every 200 ms, and only when
something has actually happened in the window, so a burst of typing costs
nothing. A copy made in another application while the editor sits idle turns
up the moment you come back to it.

Copying the same text again moves its row to the front instead of making a
second one. The list is there to save you a search, not to record repetition.

## What a row says

A row is a label, not the text. It shows the first line that has something on
it, with tabs and runs of blanks squeezed to one space, cut at 120 characters,
and says how many more lines came with it:

```
1 proc addFloat(x, y: float): float =  (+3 lines)
2 addFloat
3 (blank)  (+1 line)
- ~/projects/nimony/lib
```

Rows past the ninth have a dash instead of a number, because `Ctrl+10` does not
exist and a number nothing can accept would be a lie. They are still one click
away.

## What it does not do

**Nothing is written to disk.** A clipboard carries passwords, licence keys and
whatever else the last window had in it. Restoring that at the next start is a
decision for whoever copied it, not one an editor should make quietly. Close
the editor and the list is gone; the newest entry is still on the system
clipboard, where you left it.

The `(x)` is the same thought at a smaller scale: something copied by mistake
stops being one keystroke away from every buffer.

## Turning it off

It is a cell like any other, so leaving it out of the `(layout ...)` turns it
off -- and then `Ctrl+<digit>` does nothing either, since a numbered row nobody
can read is not a row anyone can pick. The list still fills up while the panel
is hidden, because what was copied while it was away is exactly what somebody
goes looking for after showing it again.

`(clipboard (lines 9))` is the size that shows all nine numbered rows; a
smaller one scrolls, and the numbers stay put either way, so a row never
changes key under the pointer.
