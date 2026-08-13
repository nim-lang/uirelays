## mkwordlist -- the word list focim ships with, extracted from a checkout.
##
##   nim c -r tools/mkwordlist.nim data/nimony.nif nimony ~/nimony/lib
##
## `index <path>` in the editor takes *every* word out of a tree, which is
## what you want for the project you are working on: a local name is worth
## completing too. A list that ships is a different thing -- it is a
## vocabulary, read by people who did not write it -- so this takes only what
## a module offers to the outside: the names marked with `*`, plus the
## keywords. Roughly a tenth of the words, and no `tmp`, `i` or `res` among
## them.
##
## Nim is not parsed here. An exported name is `name*` where the `*` sticks to
## the name and what follows is not a letter -- which is every `proc f*(`,
## `field*:`, `Type*[T]` and `const c* =` there is, and no multiplication
## except the rare `a*(b)` written without spaces. A word too many costs one
## line in a listing; parsing Nim to avoid it would cost a compiler.

import std/os
import ../src/widgets/wordindex

const Keywords = [
  "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct",
  "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
  "for", "from", "func", "if", "import", "in", "include", "interface", "is",
  "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
  "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
  "return", "shl", "shr", "static", "template", "try", "tuple", "type",
  "using", "var", "when", "while", "xor", "yield"]

const WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '\128'..'\255'}
const NameStart = {'a'..'z', 'A'..'Z', '_', '\128'..'\255'}

proc exportedNames(text: string; dest: var WordBag) =
  var i = 0
  while i < text.len:
    if text[i] in NameStart and (i == 0 or text[i-1] notin WordChars):
      let start = i
      while i < text.len and text[i] in WordChars: inc i
      if i < text.len and text[i] == '*' and
         (i + 1 >= text.len or text[i+1] notin WordChars) and
         i - start >= MinWordLen:
        dest.add text[start ..< i]
    else:
      inc i

proc walk(root: string; dest: var WordBag; files: var int) =
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    for kind, p in walkDir(dir):
      let name = p.extractFilename
      if name.len == 0 or name[0] == '.' or name == "nimcache": continue
      case kind
      of pcDir, pcLinkToDir: stack.add p
      else:
        if p.splitFile.ext in [".nim", ".nims"]:
          exportedNames(readFile(p), dest)
          inc files

proc main =
  if paramCount() < 3:
    quit "usage: mkwordlist <out.nif> <name> <path>..."
  let outFile = paramStr(1)
  var ws = WordSet(name: paramStr(2))
  var bag = WordBag()
  for k in Keywords: bag.add k
  var files = 0
  for i in 3 .. paramCount():
    let p = expandTilde(paramStr(i))
    if fileExists(p): exportedNames(readFile(p), bag); inc files
    elif dirExists(p): walk(p, bag, files)
    else: quit "no such path: " & p
  ws.words = bag.words
  createDir(outFile.parentDir)
  writeFile(outFile, ws.toNif)
  echo ws.words.len, " words from ", files, " files -> ", outFile

main()
