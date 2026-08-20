## Tests for `filesearch`: where a search for a file starts, what counts as a
## match for a name typed with pieces missing, and which of two matches is the
## better one. All of it is path arithmetic over a tree built here; nothing
## draws and nothing is read.

import std/[os, strutils]
import widgets/filesearch

var failures = 0

proc check(name: string; cond: bool; detail = "") =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name, (if detail.len > 0: "  -- " & detail else: "")

proc equals(name: string; got, want: string) =
  check(name, got == want, "got '" & got & "' want '" & want & "'")

# ---------------------------------------------------------------------------
# A project to search
# ---------------------------------------------------------------------------

let root = getTempDir() / "focim-filesearchtest"
removeDir root

proc file(path: string; text = "x\n") =
  createDir (root / path).parentDir
  writeFile(root / path, text)

file "proj/proj.nimble", "# a package\n"
file "proj/README.md"
file "proj/src/hexer/xelim.nim"
file "proj/src/hexer/hexer.nim"
file "proj/src/nimony/sem.nim"
file "proj/src/hastur.nim"
file "proj/icons/hastur.rc"
file "proj/icons/hastur.ico"
file "proj/apps/xelim_helper.nim"
file "proj/vendor/deep/down/here/xelim.nim"
file "proj/.hidden/xelim.nim"
file "proj/nimcache_win/xelim.nim"
file "proj/build/tool"          # no extension: a binary, not a source file
file "proj/build/tool.o"        # build output

let proj = root / "proj"

proc found(arg: string; prefer: seq[string] = @[]): string =
  var truncated = false
  result = findInTrees(@[proj], prefer, arg, truncated)
  check("not truncated: " & arg, not truncated)
  if result.startsWith(proj & DirSep):
    result = result[proj.len + 1 .. ^1].replace(DirSep, '/')

# ---------------------------------------------------------------------------
echo "where a search starts:"
# ---------------------------------------------------------------------------

equals("a .nimble above the file names the project",
       searchRoot(proj / "src" / "hexer"), proj)

createDir root / "vcs" / "a" / "b"
createDir root / "vcs" / ".git"
equals("so does a .git", searchRoot(root / "vcs" / "a" / "b"), root / "vcs")

createDir root / "loose" / "sub"
equals("a directory nothing above claims is its own project",
       searchRoot(root / "loose" / "sub"), root / "loose" / "sub")

equals("the home directory is never a place to start",
       searchRoot(getHomeDir()), "")
equals("nor is the root of the file system",
       searchRoot($DirSep), "")
equals("nor anything the home directory is inside of",
       searchRoot(getHomeDir().parentDir), "")

# ---------------------------------------------------------------------------
echo "finding a file by what was typed:"
# ---------------------------------------------------------------------------

equals("the name of a file three directories down -- what a flat search misses",
       found("xelim.nim"), "src/hexer/xelim.nim")
equals("the name without its extension",
       found("xelim"), "src/hexer/xelim.nim")
equals("a piece of the path, which pins down which one is meant",
       found("hexer/xelim.nim"), "src/hexer/xelim.nim")
equals("a piece of the path with slashes the other way round",
       found("hexer\\xelim.nim"), "src/hexer/xelim.nim")
equals("a directory, by its own name", found("hexer"), "src/hexer")
equals("something nothing is called", found("nosuchthing.nim"), "")

# ---------------------------------------------------------------------------
echo "which of two matches wins:"
# ---------------------------------------------------------------------------

equals("the file whose whole name it is, over one that merely starts with it",
       found("xelim.nim"), "src/hexer/xelim.nim")
equals("a prefix match is still a match when nothing else is",
       found("xelim_h"), "apps/xelim_helper.nim")
equals("and so is a fragment from the middle",
       found("_helper"), "apps/xelim_helper.nim")
equals("the .nim beats the .rc and the .ico of the same name",
       found("hastur"), "src/hastur.nim")
equals("the shallow copy beats the one vendored six directories down",
       found("xelim.nim"), "src/hexer/xelim.nim")
equals("a directory the command was typed in decides a tie",
       found("hastur", @[proj / "icons"]), "icons/hastur.rc")

# ---------------------------------------------------------------------------
echo "the same question asked of one directory:"
# ---------------------------------------------------------------------------

proc listed(dirs: seq[string]; arg: string): string =
  ## `recurse = false`: the listings of `dirs` and no further, which is what a
  ## caller asks before it asks for the whole project.
  var truncated = false
  result = findInTrees(dirs, dirs, arg, truncated, recurse = false)
  if result.startsWith(proj & DirSep):
    result = result[proj.len + 1 .. ^1].replace(DirSep, '/')

equals("a name with pieces missing, in the directory one is standing in",
       listed(@[proj / "src" / "hexer"], "xelim"), "src/hexer/xelim.nim")
equals("what is one directory down is not in its listing",
       listed(@[proj / "src"], "xelim"), "")
equals("and neither is a path, which has nowhere to be relative to here",
       listed(@[proj], "hexer/xelim.nim"), "")
check("two directories, one inside the other, are both listed",
      listed(@[proj / "src", proj / "src" / "hexer"], "xelim").len > 0)

# ---------------------------------------------------------------------------
echo "what is not searched:"
# ---------------------------------------------------------------------------

check("a dotted directory is left alone",
      not found("xelim.nim").startsWith(".hidden"))
check("and so is every flavour of nimcache",
      not found("xelim.nim").startsWith("nimcache"))
equals("build output is not a file anybody meant", found("tool.o"), "")
equals("neither is a file without an extension", found("tool"), "")

removeDir root
if failures > 0:
  quit "FAILURE: " & $failures & " test(s) failed"
echo "all file search tests passed"
