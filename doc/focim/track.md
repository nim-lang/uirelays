# Tracking

`Ctrl+click` (`Cmd+click` on macOS) on a name in a `.nim` file asks a compiler
where that name is: where it is declared, and everywhere it is used. The
answers come back as a listing under the caret -- the same one `Ctrl+Space`
puts there -- with one row per place. `Up`/`Down` picks a row, `Enter` or `Tab`
goes there, `Esc` drops it.

```
def  src/widgets/synedit.nim:1877   proc gotoLine*(s: var SynEdit; line, col: int) =
use  apps/focim.nim:704             tabs.ed.gotoLine(tabAct.line + 1, 0)
use  apps/focim.nim:1683            tabs.ed.gotoLine(current + 1, 0)
```

This is the one place in focim where a compiler is in the loop. `Ctrl+Space`
knows which names *exist*; this knows what one *means*, which is a question
only a compiler can answer.

## One question, not two

Every other editor has two commands here -- "go to declaration" and "find all
usages" -- and makes you say which one you meant. focim asks for both at once
and offers the list, because the click cannot say which one it was: the same
click on the same name means the declaration while you are reading and the
usages while you are changing something.

Insisting on a single answer would not have worked in any case. A forward
declaration is two declarations:

```nim
proc twice(s: string): string          # this is a declaration
proc twice(s: string): string = s & s  # and so is this
```

so "go to declaration" has two answers here and something has to be picked
from. Having built that, "and the usages as well" costs one more row each.

A declaration is also a mention of its own name, so both compilers report it
twice -- once as a definition and once as a usage. One row per *place* is what
a list to pick from wants, so the two are folded into the one that says more.
A single place left over is not a choice at all: focim goes straight there
without asking.

## The project

A compiler cannot type-check one file; it needs the project the file belongs
to. focim computes it the way nimsuggest's `--find` does, walking up from the
file's own directory: a directory holding `pkg.nimble`, `pkg.nims`, `pkg.cfg`
or `pkg.nimcfg` beside a `pkg.nim` names the project, and a nimble package
whose source sits in `src/` is found there too. Two `.nimble` files in one
directory give up rather than guess.

A file that belongs to no project is its own project, which is exactly right
for a standalone script.

The answer is only ever as good as the project this finds. A library module
that the package's main module does not import is checked as part of a project
it is not in, and the compiler then truthfully knows nothing about the name --
`nothing found for 'gotoLine'`. The status bar names the project every query
goes to (`looking for 'gotoLine' in uirelays.nim ...`) so that an answer that
looks wrong can be read as what it is: the right answer to the wrong question.

## The compilers

| Config | What runs |
|--------|-----------|
| `nim` | `nim track PROJECT --defusages:FILE,LINE,COL` |
| `nimony` | `nimony check PROJECT --def:...` and `--usages:...` |
| `none` | nothing; `Ctrl+click` says so |

`nim track` answers both halves in one go. Nimony has a switch per half, so it
is asked twice -- the second run is nearly free, since the first one left the
nifcache built.

The two also differ in what they print and where the file name sits in it, so
the answer is read for the shape both versions have rather than by counting
fields: a record begins with `def` or `use`, and the file, the line and the
column are the first field followed by two numbers. That is what keeps one
reader working for two compilers, and for the next version of either.

The compiler runs in a thread of its own. A project of any size takes seconds
to answer, and a window that stops for seconds is a broken window -- so the
status bar says `looking for 'gotoLine' in focim.nim ...` and the editor stays
an editor until the answer arrives. One question at a time: a second click
while one is out says so rather than starting a second compiler.

Nothing about it can take the editor down. A compiler that is not installed, a
project that does not compile, a name nothing knows and a file that has been
deleted since the compiler saw it are all a line in the status bar.

## The config

```
(track
  (compiler "nim")     # "nim", "nimony", or "none" for nobody
  (exe "/home/me/nim/bin/nim"))
```

`(exe ...)` names the binary to run. Left out, the compiler's own name is used
and found on the `PATH` like any other command -- which is what makes
`(track (compiler "nim"))` enough for a normal installation, and what lets a
checkout point at the compiler it is being built with. A config that says
nothing about tracking gets `nim`.

## What it does not do

There is no completion from the compiler, no type under the pointer, no
rename, no diagnostics in the gutter. `Ctrl+hover` underlines the name the
click would ask about and nothing more. Those are all worth having and none of
them is here yet; what is here is the one question that made the difference
between reading code in focim and reading it somewhere else.
