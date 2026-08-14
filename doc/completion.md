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

Nothing is taken out of a comment or a string literal. What is written there is
English -- `because`, `otherwise`, `example` -- and a listing of identifiers
with English in it is a listing nobody reads. It is not a small share either:
of the 10139 words Nimony's standard library appeared to hold, 5169 were prose.

## Matching

Candidates come in three groups, in this order, alphabetical within each:

1. what starts with the prefix exactly,
2. what starts with it in Nim's sense -- the first letter decides case, and
   everything after it ignores case and underscores, so `add_float` is offered
   for `addF`,
3. what merely contains it.

## The panel

The `prediction` cell says what could be written next, numbered, and `Ctrl+1`
.. `Ctrl+9` take a row -- as does clicking it, which hands the caret straight
back to the editor. Nine rows, because a tenth would be one no key could
accept. One `Ctrl+Z` takes a row back however many tokens it was.

Unlike the popup it offers **phrases**: runs of tokens somebody has written
before. Type `case ` and it offers `case typ.kind`; type `result.` and it
offers `result.add(`. Rows are looked up under as much of the line as agrees
with one, widest first, so agreeing with four tokens beats agreeing with one.
When a name is being typed the last two rows are kept for plain words, since a
phrase beginning with a name implies the name but not the other way round. At
the start of a line, where there is nothing to go on, what is offered is what
tends to begin one.

Nothing has to be summoned and nothing has to be dismissed, so there is no
selection to move and the arrow keys never leave the editor. That is the point
of a panel over a popup: a popup has to cover the code it is about, so it must
be modal, and being modal costs a key to open, a key to close, and the arrows
while it is up.

It is a cell like any other, so leaving it out of the `(layout ...)` turns it
off -- and then `Ctrl+<digit>` does nothing, since a numbered row nobody can
read is not a row anyone can pick. `(prediction (lines 9))` is the size that
shows all nine; a smaller one scrolls, and the numbers stay put either way.

### Which phrases exist

A phrase is two to five tokens on one line, and it begins with a name of at
least two characters -- the same name the word index would have taken, since a
suggestion offered after one keystroke to save a comma is not worth a row.
Tokens are what the language reads as one thing: a dotted name (`typ.kind`), a
run of operator characters (`..<`), a character literal (`'A'`), a number with
its type on it (`1'u8`). That is why `c in {'A'..` finds `in {'A'..'Z'}` --
counted character by character it would be nine tokens deep and out of reach.

The line in front of the caret is cut up by that very same lexer, so asking for
five tokens reaches exactly as far as a five-token phrase does. It stops at a
comment or a string literal on the way, because there is nothing to predict
inside a message and `echo "a` asks for nothing.

Off disk, a phrase is kept only if it was seen **twice, in two different
files** -- once is a line somebody wrote, twice is a way of writing, and twice
in the same file is often a machine that wrote it. `uint64x2(hi:` occurs 620
times in Nimony's standard library, all of them in one generated table;
counting alone cannot tell that from an idiom, and asking for a second file
throws out two phrases in three while leaving `result =` and `for i in 0 ..<`
where they are. Indexing a single file asks only for the second sighting, since
there the second file does not exist.

In an open buffer everything counts once: the file being edited is the one
corpus where a single occurrence is already the point. Buffer phrases are also
offered first, for the same reason buffer words are.

A chain of nested phrases (`for i in`, `for i in 0`, `for i in 0 ..<`)
collapses to its longest member whenever the shorter one was never seen on its
own, so the rows say nine things instead of three things three times.

## The prompt

Both the terminal and the status bar take these:

| Command | What it does |
|---------|--------------|
| `index <path>` | Read every source file under `<path>` and remember its words and phrases |
| `index` | Say how much there is and where it came from |
| `unindex <path>` | Forget that path again, and delete its file |

Indexing runs a few files per frame with its progress in the status bar, so a
large tree does not stop the editor. It reads what the editor can colorize --
`.nim`, `.c`, `.py` and the rest of `fileExtToLanguage` -- except Markdown,
whose words are English rather than identifiers. Files over a megabyte are
skipped as generated, and a tree is abandoned after 5000 files with a note
saying so rather than grinding on quietly. A tree with more than 200000
distinct phrases in it loses the ones seen only once, with a note saying that
too.

For scale: Nimony's whole repository is 1356 files, and gives 23000 words and
58000 phrases in about half a second of scanning spread over frames, a 1.4 MB
file and 50 ms to read it back at the next start.

## The file

A word list is a text file: the first line says where it all came from, then
the words one per line, then the phrases with two numbers in front of them --
how often each was seen, and how often it began a line.

```
/home/me/nimony/lib
abs
add
addFloat
31 12 result.add
9 9 case typ.kind
```

A list like this wants no syntax. There is no nesting in it, no attribute and
nothing to quote -- a word never contains a space or a newline, and a phrase
never contains a newline and always begins with a name, so a leading integer
can only be a count. `[]=` and `=destroy` are simply themselves on a line of
their own, which is not true of any format with an escape in it. Each of the
two runs is sorted, so re-indexing a directory produces a diff of what changed
rather than of everything; blank lines and indentation are ignored, and a
phrase line with only one number, or none, still reads the way it looks -- so
a list edited by hand keeps working.

`index` stores one file per path under `~/.config/focim/words/`. The shipped
list is the same format, made once from a Nimony checkout:

```
nim c -r tools/mkwordlist.nim data/nimony.txt nimony ~/nimony/lib
```

That tool takes only the *exported* names -- `name*` -- plus the keywords,
which is around 1900 words for Nimony's standard library. `index` takes every
name instead: in the project you are editing a local name is worth completing
too, while a vocabulary that ships is read by people who did not write it.

The phrases are not filtered that way, because "exported" means nothing to a
construct -- `for i in 0 ..<` is how the language is written whoever wrote it
-- so the shipped list carries what `index` would have kept: 7300 phrases out
of the standard library, which is what makes `case `, `result.` and `c in {'A'`
say something in a project that has not been indexed at all. 145 KB in total,
and 12 ms of the start.
