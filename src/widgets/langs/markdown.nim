## Markdown parsing that does not need an editor buffer -- link hit-testing,
## heading slugs, and full-line image recognition.

import std/strutils

proc parseMarkdownImagePath*(line: string; path: var string): bool =
  ## Parse a full-line markdown image: ![alt](path)
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  if i + 1 >= line.len or line[i] != '!' or line[i + 1] != '[':
    return
  var closeBracket = -1
  var k = i + 2
  while k < line.len:
    if line[k] == ']':
      closeBracket = k
      break
    inc k
  if closeBracket < 0 or closeBracket + 1 >= line.len or line[closeBracket + 1] != '(':
    return
  var closeParen = -1
  k = closeBracket + 2
  while k < line.len:
    if line[k] == ')':
      closeParen = k
      break
    inc k
  if closeParen < 0:
    return
  var tail = closeParen + 1
  while tail < line.len and line[tail] in {' ', '\t'}: inc tail
  if tail != line.len:
    return
  path = line[(closeBracket + 2) ..< closeParen]
  result = path.len > 0

proc findMarkdownLinkAt*(line: string; col: int): tuple[url: string; a, b: int] =
  ## If column `col` sits on a `[label](url)`, `![alt](url)` or `<url>` in
  ## `line`, return the URL and the column range to underline (label text, or
  ## the autolink body). Otherwise `("", -1, -1)`.
  result = ("", -1, -1)
  if col < 0 or col >= line.len: return
  var i = 0
  while i < line.len:
    if line[i] == '<' and i + 1 < line.len and line[i + 1] notin {' ', '\t', '<'}:
      var j = i + 1
      while j < line.len and line[j] notin {'>', ' ', '\t'}: inc j
      if j < line.len and line[j] == '>' and j > i + 1:
        if col >= i and col <= j:
          return (line[(i + 1) ..< j], i + 1, j - 1)
        i = j + 1
        continue
    let bang = line[i] == '!' and i + 1 < line.len and line[i + 1] == '['
    let openBracket = if bang: i + 1 else: i
    if openBracket < line.len and line[openBracket] == '[':
      let labelStart = openBracket + 1
      var j = labelStart
      while j < line.len and line[j] != ']': inc j
      if j < line.len and j + 1 < line.len and line[j + 1] == '(':
        var k = j + 2
        let urlStart = k
        while k < line.len and line[k] != ')' and line[k] != ' ': inc k
        let urlEnd = k
        var close = k
        while close < line.len and line[close] != ')': inc close
        if close < line.len:
          let linkStart = if bang: i else: openBracket
          if col >= linkStart and col <= close:
            var url = line[urlStart ..< urlEnd]
            # Titles after the URL are not part of the target.
            while url.len > 0 and url[^1] in {' ', '\t'}: url.setLen url.len - 1
            if labelStart <= j - 1:
              return (url, labelStart, j - 1)
            return (url, linkStart, close)
          i = close + 1
          continue
    inc i

proc markdownHeadingSlug*(title: string): string =
  ## GitHub-ish slug: lowercase, keep letters/digits, spaces become `-`.
  for c in title.strip:
    let lc = toLowerAscii(c)
    if lc in {'a'..'z', '0'..'9'}:
      result.add lc
    elif lc in {' ', '-'}:
      if result.len == 0 or result[^1] != '-': result.add '-'
  while result.len > 0 and result[^1] == '-':
    result.setLen result.len - 1
