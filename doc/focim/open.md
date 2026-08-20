# Opening a file

`o <name>` / `open <name>`, in the terminal or on the prompt. `Ctrl+P` is the
prompt with `open ` already typed into it.

There is no file dialog and no fuzzy-finder window. What there is instead is a
name, typed with as much of it left out as one can get away with:

```
o xelim.nim        -> src/hexer/xelim.nim
o xelim            -> src/hexer/xelim.nim
o hexer/xelim.nim  -> src/hexer/xelim.nim
o hexer            -> the explorer, showing src/hexer
```

A relative path means what it would mean where it was typed: in the terminal,
relative to the directory the terminal is in; on the prompt, relative to the
file being edited. An absolute path is itself and nothing is guessed about it.

## Three questions, cheapest first

Each is asked only because the one before it said no.

1. **The path as given**, against the directory the command was typed in and
   the directory of every open tab. This is the file one was just looking at,
   and it costs a `fileExists`.
2. **The listings of those same directories**, for a name with pieces missing.
   One `walkDir` each.
3. **The project those directories are in**, walked.

The first two look at a handful of directories and answer instantly. What they
cannot answer is a project that has any shape to it: with only
`nimony/README.md` open, `xelim.nim` is three directories away in `src/hexer/`
and no list of open directories will ever hold it. That is what the walk is
for, and why it is last.

Steps 2 and 3 rank their candidates the same way, so the quick search and the
thorough one can never disagree about which of two files was meant.

## Where the walk starts, and where it stops

The project of a directory is the nearest directory above it that a version
control system or a package manager has claimed -- a `.git`, `.hg`, `.svn` or
`.jj`, or a `*.nimble`. That is what "the project" means to everybody who is
not a build system. A directory that nothing above it claims is its own
project, which is the right answer for a directory of loose files.

The walk never starts at the home directory, at the root of the file system,
or at anything either of them is inside of: a mistyped name must not turn into
a walk over everything one owns. It is bounded at 200,000 directory entries as
well, and says so when it stopped there rather than reporting the name as
missing:

```
cannot open: xelim.nim -- and the tree was too big to search all of it
```

Nothing is cached and no index is built. A file created a second ago is one of
the answers, and a walk over a checkout with its dependencies and three build
directories in it -- thirty thousand files -- takes about ten milliseconds,
which is less than the keystrokes that asked for it.

Left out of the walk: dotted directories, anything whose name starts with
`nimcache`, `node_modules`, `__pycache__`, build output (`.o`, `.exe`, `.so`
and the rest), and files with no extension at all -- far more often a binary
that got built here than the source anybody meant.

## Which of two files was meant

In this order:

1. **How exactly the name matches.** The whole path tail (`hexer/xelim.nim`),
   then the same ignoring case, then the name without its extension (`xelim`),
   then a prefix of the name, then a fragment from the middle of it. Only a
   *bare* name is guessed at that far: `sub/dir/thing` was meant to be a path,
   and answering it with a file from somewhere else would be a surprise.
2. **How near it is to where the command was typed** -- that directory first,
   then the directory of every open tab, in tab order.
3. **What kind of thing it is.** `.nim` before `.c` before `.md` before
   something an editor has no business with, and a file before a directory.
   This is what makes `o hastur` mean `src/hastur.nim` and not
   `icons/hastur.rc`, the two being otherwise the same match.
4. **How shallow it is**, so `src/hexer/xelim.nim` beats a vendored copy of it
   six directories down.
5. **Alphabetically**, so that the answer never depends on the order the file
   system happened to hand things out in.

A directory is only ever matched by its whole name, never by a fragment, and a
directory that matches is shown in the explorer rather than opened -- a
directory is not a buffer.
