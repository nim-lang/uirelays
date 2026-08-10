## Markdown helpers that need no window -- link hit-testing and heading slugs.

import ../src/widgets/langs/markdown

template check(cond: bool; msg: string) =
  if not cond: quit "FAILURE " & msg

proc expectLink(line: string; col: int; url: string; a, b: int) =
  let hit = findMarkdownLinkAt(line, col)
  check hit.url == url, "url at col " & $col & " in `" & line &
    "`: got `" & hit.url & "`, want `" & url & "`"
  check hit.a == a and hit.b == b, "range at col " & $col & " in `" & line &
    "`: got " & $hit.a & ".." & $hit.b & ", want " & $a & ".." & $b

proc expectMiss(line: string; col: int) =
  let hit = findMarkdownLinkAt(line, col)
  check hit.a < 0, "expected no link at col " & $col & " in `" & line & "`"

# [label](url)
expectLink("see [NIF](nif-spec.md) now", 5, "nif-spec.md", 5, 7)
expectLink("see [NIF](nif-spec.md) now", 10, "nif-spec.md", 5, 7)
expectLink("see [NIF](nif-spec.md) now", 14, "nif-spec.md", 5, 7)
expectMiss("see [NIF](nif-spec.md) now", 0)
expectMiss("see [NIF](nif-spec.md) now", 22)

# optional title after the URL
expectLink("""[x](a.md "title")""", 1, "a.md", 1, 1)

# image form still yields a target
expectLink("![alt](pic.png)", 3, "pic.png", 2, 4)

# autolink
expectLink("go <language.md> here", 5, "language.md", 4, 14)

# fragment-only and path#frag are left intact for the app to split
expectLink("[t](#goals)", 1, "#goals", 1, 1)
expectLink("[t](design.md#goals)", 1, "design.md#goals", 1, 1)

check markdownHeadingSlug("Goals") == "goals", "Goals slug"
check markdownHeadingSlug("Args configuration system") ==
  "args-configuration-system", "multi-word slug"
check markdownHeadingSlug("  Hello, World!  ") == "hello-world", "punct slug"

echo "ok"
