# Search and replace

There is no find dialog. Searching is a command like every other one, typed
into the status bar or the terminal:

| | |
|---|---|
| `find <text>` or `f <text>` | every match in this tab |
| `findall <text>` | every match in every open tab |
| `find` | forget the last search, and the highlighting with it |
| `next`, `prev` / `v` | move to the next match, or the one before |
| `replace <text> <with>` or `r <text> <with>` | ask about every match in this tab |
| `replaceall <text> <with>` | the same, in every open tab |

`Ctrl+F` is `find ` already typed into the prompt, `F3` and `Shift+F3` are
`next` and `prev`, and `Ctrl+P` is `open ` -- the three things one reaches for
without thinking.

Text with a space in it is written `f 'two words'` or `f "two words"`.

## Where a search starts

At the caret, not at the top of the file: a search is made where one is
looking. `next` walks forward from there and wraps around at the end; with
`findall` it walks into the next tab that has a match instead, and comes back
around to this one.

Every match is highlighted, and the one the search is *on* has the color of a
selection, so one glance says where `next` will land. Matches in other tabs are
highlighted too, in the plain marker color -- switching to such a tab shows
them without searching again.

Editing the text throws the search away. The positions it found have moved,
and highlighting where a match *used to be* would be worse than showing
nothing. `F3` after an edit looks again for the same text rather than
answering "not found" about a search nobody withdrew.

## Options

A word of letters after the text says how to look:

| | |
|---|---|
| `i` | ignore case -- and what a search does anyway |
| `c` or `p` | precise: case matters |
| `w` or `b` | whole words only |
| `s` | not whole words, undoing a `w` |
| `f` | this file only, so a `findall` stays where it is |

So `f Foo c` finds `Foo` and not `foo`, and `f open w` finds `open` but not
`openFile`. A search for a single letter is a whole-word search without being
asked: `f i` is meant to find the variable, and every third character in the
file would not be an answer.

There is no regular expression option. nimedit had one compiled out, and this
is the same decision made in the open.

## Replacing

`replace` finds every match and then asks about them one at a time:

```
'foo' 1/17  Replace? [yes|no|all|abort]
```

The answer goes in the prompt -- the status bar, where the question is -- and
the caret moves there by itself, even when the `replace` was typed in the
terminal. `yes`, `no`, `all` or `abort`; `y`, `n`, `a` do as well. `yes`
replaces this match and moves to the next, `no` leaves it and moves on, `abort`
stops and says how many were replaced. `all` replaces every match of that
search, including the ones already passed over: `all` means all.

While a question is up, a line typed in the prompt answers it instead of being
run. The terminal is never asked anything: `yes` and `no` are programs on the
machine, and the place that runs programs should keep running them. Any other
command withdraws the question.

One `Ctrl+Z` takes back one replacement, however long the text that went in.

A replacement may be nothing: `r debugEcho ''` deletes every match.

## What it does not do

**It does not touch a file that is not open.** The search walks the open tabs,
which is what `findall` means -- a project-wide search would be a different
feature with a different result panel, and the terminal is right there with
`grep`.

**It does not filter lines.** nimedit's `filter` command hid every line without
a match; that needs a display mode this editor's buffer does not have.
