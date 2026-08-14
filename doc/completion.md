# Completion

`Ctrl+Space` in the editor lists the words that could continue what is being
typed. Type on to narrow the list, `Up`/`Down` to pick, `Enter` or `Tab` to
take it, `Esc` to drop it. One `Ctrl+Z` takes the whole completion back --
not one character of it.

The same words are always on show in the `prediction` panel, which needs no
key to appear. See [The panel](#the-panel) below.

Nothing here is semantic. There is no compiler in the loop and nothing knows
that `add` is a proc or what its arguments are. What it knows is which names
exist, which is enough to never have to type one twice.

## Where the words come from

| Source | When |
|--------|------|
| The open buffers | Always, a couple of hundred lines per frame |
| `index <path>` | Once; the result is stored and comes back on the next start |
| `data/nimony.txt` | Shipped with the editor, loaded at startup |

The shipped list is looked for in `data/nimony.txt` next to the binary and one
directory above it -- the second is what a checkout looks like, where the
binary sits in `apps/`. It is optional: without it the editor starts on the
open buffers alone, and `index` fills the rest in.

A word is an identifier of at least two characters. A token that starts with a
digit is not one, which is what keeps `0xffff` out. The word the caret is
inside is left out of the index, so a half-typed name is never offered as its
own completion.

## Matching

Candidates come in three groups, in this order, alphabetical within each:

1. what starts with the prefix exactly,
2. what starts with it in Nim's sense -- the first letter decides case, and
   everything after it ignores case and underscores, so `add_float` is offered
   for `addF`,
3. what merely contains it.

## The panel

The `prediction` cell shows the same candidates as the popup, numbered, and
`Ctrl+1` .. `Ctrl+9` take a row -- as does clicking it, which hands the caret
straight back to the editor. Nine rows, because a tenth would be one no key
could accept.

Nothing has to be summoned and nothing has to be dismissed, so there is no
selection to move and the arrow keys never leave the editor. That is the point
of a panel over a popup: a popup has to cover the code it is about, so it must
be modal, and being modal costs a key to open, a key to close, and the arrows
while it is up.

It is a cell like any other, so leaving it out of the `(layout ...)` turns it
off -- and then `Ctrl+<digit>` does nothing, since a numbered row nobody can
read is not a row anyone can pick. `(prediction (lines 9))` is the size that
shows all nine; a smaller one scrolls, and the numbers stay put either way.

Since both ask `complete` with the same prefix, row 3 of the panel is row 3 of
the popup whenever both are up. What the panel does *not* have yet is anything
to say when the caret is not behind a word; it says so in place of the rows.

## The prompt

Both the terminal and the status bar take these:

| Command | What it does |
|---------|--------------|
| `index <path>` | Read every source file under `<path>` and remember its words |
| `index` | Say how many words there are and where they came from |
| `unindex <path>` | Forget that path again, and delete its file |

Indexing runs a few files per frame with its progress in the status bar, so a
large tree does not stop the editor. It reads what the editor can colorize --
`.nim`, `.c`, `.py` and the rest of `fileExtToLanguage` -- except Markdown,
whose words are English rather than identifiers. Files over a megabyte are
skipped as generated, and a tree is abandoned after 5000 files with a note
saying so rather than grinding on quietly.

## The file

A word list is a text file: the first line says where the words came from and
every line after it is one word.

```
/home/me/nimony/lib
abs
add
addFloat
```

A list of words wants to be a list of words. There is no nesting in it, no
attribute and nothing to quote -- a word never contains a space or a newline
-- so `[]=` and `=destroy` are simply themselves on a line of their own, which
is not true of any format with an escape in it. The list is sorted, so
re-indexing a directory produces a diff of what changed rather than of
everything, and blank lines and indentation are ignored, so a list edited by
hand reads the same as one written by the editor.

`index` stores one file per path under `~/.config/focim/words/`. The shipped
list is the same format, made once from a Nimony checkout:

```
nim c -r tools/mkwordlist.nim data/nimony.txt nimony ~/nimony/lib
```

That tool takes only the *exported* names -- `name*` -- plus the keywords,
which is around 1900 words for Nimony's standard library. `index` takes every
word instead: in the project you are editing, a local name is worth completing
too, while a vocabulary that ships is read by people who did not write it.
