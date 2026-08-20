## filesearch.nim -- finding the file somebody named a fragment of.
##
## `open xelim.nim` has to work from wherever one happens to be standing. The
## cheap answers -- the path as typed, the same name beside a file that is
## already open -- cover the file one was just looking at and nothing else, and
## a project is not flat: with `nimony/README.md` open, `xelim.nim` is three
## directories away in `src/hexer/` and no list of open directories will ever
## contain it.
##
## So when the cheap answers come up empty, the project gets walked.
## `searchRoot` says where the walk starts -- the nearest directory above that
## a version control system or a package manager has claimed, which is what
## "the project" means to everybody who is not a build system -- and
## `findInTrees` walks down from there and keeps the best match it saw.
##
## Two things keep that from being a bad idea. The walk never starts at the
## home directory or above it, so a mistyped name cannot turn into a walk over
## everything one owns; and it is bounded, so a tree that is enormous by
## accident stops rather than grinding. Nothing is cached: a file that was
## created a second ago is one of the answers, and the whole walk costs less
## than the keystrokes that asked for it.
##
## What makes an answer better than another, in this order:
##
## 1. how exactly the name matches -- the whole path tail, then the file name,
##    then the file name without its extension, then a prefix of it, then a
##    fragment of it;
## 2. how near it is to where the command was typed -- the directory it was
##    typed against, then the directory of every open tab;
## 3. what kind of thing it is: `.nim` before `.c` before `.md` before
##    something an editor has no business with, and a file before a directory;
## 4. how shallow it is, so `src/hexer/xelim.nim` beats a vendored copy of it
##    six directories down;
## 5. alphabetically, so that the answer never depends on the order the file
##    system happened to hand things out in.

import std/[os, strutils]

const
  ExtensionsToIgnore* = [
    ".ppu", ".o", ".obj", ".dcu",
    ".map", ".tds", ".err", ".bak", ".pyc", ".exe", ".rod", ".pdb", ".idb",
    ".idx", ".ilk", ".dll", ".so", ".a"
  ]

proc ignoreFile*(f: string): bool =
  ## Build output and backups: what nobody means when they name a file.
  let (_, name, ext) = f.splitFile
  result = name.len > 0 and name[0] == '.' or ext in ExtensionsToIgnore or
           f == "nimcache"

const
  MaxVisited* = 200_000
    ## Directory entries one search may look at. Far more than any project has
    ## -- a checkout with its dependencies and three build directories in it
    ## comes to thirty thousand -- and little enough that a walk which has
    ## wandered somewhere enormous stops instead of grinding.

proc normDir(dir: string): string =
  result = dir
  while result.len > 1 and result[^1] == DirSep:
    result.setLen result.len - 1

proc isSep(c: char): bool {.inline.} = c == '/' or c == '\\'

proc isBareName*(s: string): bool =
  ## True when `s` names a file rather than a path to one. `parentDir` does not
  ## answer this -- it says "." for a bare name, not "" -- and the difference
  ## decides whether guessing is allowed at all: `sub/dir/thing` was meant to
  ## be a path, and answering it with a file from somewhere else would be a
  ## surprise.
  for c in s:
    if isSep(c): return false
  result = true

proc hasRootMarker(dir: string): bool =
  ## What says "the tree starts here": a version control system's directory or
  ## a package manager's manifest. Both are things one puts at the top of a
  ## project and nowhere else, which is exactly the question being asked. A
  ## `.git` may be a file rather than a directory -- that is what a worktree
  ## and a submodule look like -- and it means the same thing.
  for vcs in [".git", ".hg", ".svn", ".jj"]:
    if dirExists(dir / vcs) or fileExists(dir / vcs): return true
  try:
    for kind, p in walkDir(dir):
      if kind == pcFile and p.splitFile.ext == ".nimble": return true
  except CatchableError:
    discard
  result = false

proc tooBig(dir, home: string): bool =
  ## The home directory, the root of the file system, and anything either of
  ## them is inside of. A walk that starts at one of those is not a search
  ## anybody asked for.
  dir.len == 0 or dir == home or isRootDir(dir) or
    home.len > dir.len and home.startsWith(dir) and isSep(home[dir.len])

proc searchRoot*(dir: string): string =
  ## Where a search for a file near `dir` starts: the nearest directory above
  ## it that a version control system or a package manager has claimed, and
  ## `dir` itself when nothing above it says anything -- a handful of files
  ## with a subdirectory or two is still a tree worth walking. "" when even
  ## `dir` is too big to walk.
  let home = normDir(getHomeDir())
  let start = normDir(dir)
  if tooBig(start, home): return ""
  var d = start
  while not tooBig(d, home):
    if hasRootMarker(d): return d
    let up = normDir(d.parentDir)
    if up == d: break
    d = up
  result = start

# ---------------------------------------------------------------------------
# What counts as a match, and which of two is the better one
# ---------------------------------------------------------------------------

proc sameChar(a, b: char; ignoreCase: bool): bool {.inline.} =
  if a == b: return true
  if isSep(a) and isSep(b): return true
  if ignoreCase: return toLowerAscii(a) == toLowerAscii(b)
  result = false

proc endsWithPart(path, tail: string; ignoreCase: bool): bool =
  ## `path` ends with `tail`, and on a component boundary: `src/hexer/xelim.nim`
  ## ends with `hexer/xelim.nim` and with `xelim.nim`, but not with `elim.nim`.
  ## Either kind of separator matches either, so a path typed with slashes
  ## finds a file on a machine that spells them backwards.
  if tail.len == 0 or path.len < tail.len: return false
  if path.len > tail.len and not isSep(path[path.len - tail.len - 1]):
    return false
  for i in 0 ..< tail.len:
    if not sameChar(path[path.len - tail.len + i], tail[i], ignoreCase):
      return false
  result = true

proc matchClass(path, arg: string; bare: bool): int =
  ## How well `path` answers to `arg`; -1 when it does not. Lower is better.
  ## Only a bare name is *guessed* at: `sub/dir/thing` was meant to be a path,
  ## and answering it with a file from somewhere else would be a surprise.
  if endsWithPart(path, arg, ignoreCase = false): return 0
  if endsWithPart(path, arg, ignoreCase = true): return 1
  if endsWithPart(path.changeFileExt(""), arg, ignoreCase = true): return 2
  if not bare: return -1
  let f = path.extractFilename.toLowerAscii
  let a = arg.toLowerAscii
  if f.startsWith(a): return 3
  if a in f: return 4
  result = -1

const
  SourceExtensions* = [
    ".nim", ".nims", ".nimble", ".nif", ".cfg", ".nimcfg",
    ".c", ".h", ".cpp", ".hpp", ".cxx", ".cc", ".m", ".mm",
    ".cs", ".java", ".js", ".ts", ".py", ".rs", ".go", ".rb", ".lua",
    ".sh", ".bat", ".ps1", ".sql", ".rc",
    ".md", ".markdown", ".rst", ".txt",
    ".json", ".yml", ".yaml", ".toml", ".ini", ".xml", ".html", ".htm", ".css"
  ]
    ## Code and prose: what an editor is for, **in the order it is for them**.
    ## A whitelist rather than a list of what to avoid, because the first is a
    ## bounded set and the second is not; and ordered, because "a file" is not
    ## a fine enough answer when two of them match a name equally well.
    ## `o hastur` in a Nim checkout means `src/hastur.nim`, not
    ## `icons/hastur.rc` and not `icons/hastur.ico` -- and nothing but this
    ## order says so, the three being the same match at the same depth with `i`
    ## coming before `s`.
    ##
    ## It only ever decides a *tie*: an extension missing from it, or ranked
    ## lower than one would like, costs nothing that naming the file more
    ## exactly does not fix.

proc kindRank(path: string; isDir: bool): int =
  ## Where this sits in `SourceExtensions`; behind all of them when it is not
  ## in the list, and behind that again when it is a directory.
  if isDir: return SourceExtensions.len + 1
  let ext = path.splitFile.ext.toLowerAscii
  for i, e in SourceExtensions:
    if e == ext: return i
  result = SourceExtensions.len

type
  Match = object
    path: string
    cls: int        ## how the name matched
    kind: int       ## what it is worth opening as, per `SourceExtensions`
    dirCls: int     ## how near its directory is to where this was typed
    depth: int      ## how far down the tree it is

proc better(a, b: Match): bool =
  if a.cls != b.cls: return a.cls < b.cls
  if a.dirCls != b.dirCls: return a.dirCls < b.dirCls
  if a.kind != b.kind: return a.kind < b.kind
  if a.depth != b.depth: return a.depth < b.depth
  result = a.path < b.path

proc depthOf(path: string): int =
  for c in path:
    if isSep(c): inc result

proc dirClass(dir: string; prefer: seq[string]): int =
  for i, d in prefer:
    if d == dir: return i
  result = prefer.len

proc skipDir(name: string): bool {.inline.} =
  ## A build directory holds a copy of everything and none of it is source.
  ## `nimcache` is rarely called just that -- `nimcache_win` beside it is one
  ## checkout's way of keeping two of them -- so the prefix is what is asked.
  name.startsWith("nimcache") or name == "node_modules" or name == "__pycache__"

# ---------------------------------------------------------------------------
# The search
# ---------------------------------------------------------------------------

proc findInTrees*(roots, prefer: seq[string]; arg: string;
                  truncated: var bool; recurse = true): string =
  ## The best file (or directory) under `roots` that `arg` names, or "".
  ## `prefer` is where the command was typed and which directories are already
  ## open, most interesting first: it decides ties, not matches. `truncated` is
  ## set when the walk stopped at `MaxVisited` -- an empty answer means
  ## something else then, and the caller can say so.
  ##
  ## `recurse = false` looks at the listings of `roots` and no further. That is
  ## the same question asked of a handful of directories instead of a project,
  ## which is what a caller asks first: it costs one `walkDir` each, and it is
  ## answered by the same ranking, so the cheap search and the thorough one can
  ## never disagree about which of two files was meant.
  truncated = false
  if arg.len == 0: return ""
  let bare = isBareName(arg)
  var best = Match(cls: -1)
  var visited = 0
  var walked: seq[string] = @[]
  for r in roots:
    let root = normDir(r)
    if root.len == 0: continue
    # A root inside one that has already been walked would walk it twice, and
    # the second walk cannot find anything the first one did not.
    var covered = false
    for w in walked:
      if root == w or (recurse and root.len > w.len and root.startsWith(w) and
                       isSep(root[w.len])):
        covered = true
        break
    if covered: continue
    walked.add root
    var stack = @[root]
    while stack.len > 0:
      let dir = stack.pop()
      let dcls = dirClass(dir, prefer)
      try:
        for kind, p in walkDir(dir):
          inc visited
          if visited > MaxVisited:
            truncated = true
            break
          let name = p.extractFilename
          if name.len == 0 or name[0] == '.': continue
          let isDir = kind in {pcDir, pcLinkToDir}
          if isDir:
            if skipDir(name): continue
            if recurse: stack.add p
          elif ignoreFile(name) or '.' notin name:
            # A file without an extension is far more often a binary that got
            # built here than the source anybody meant.
            continue
          let cls = matchClass(p, arg, bare)
          if cls < 0: continue
          let m = Match(path: p, cls: cls, kind: kindRank(p, isDir),
                        dirCls: dcls, depth: depthOf(p))
          if best.cls < 0 or m.better(best): best = m
      except CatchableError:
        discard
      if truncated: break
    if truncated: break
  result = if best.cls >= 0: best.path else: ""
