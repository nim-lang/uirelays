import std/[os, strutils]

proc fatal(msg: string) = quit "FAILURE " & msg

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0: fatal cmd


template execBackend(backend: string) =
  for example in walkFiles("examples/*.nim"):
    let command: string = [
    "nim c",
    "--outdir:testArtifacts", # give the bins their own folder so they don't pollute the src folder
    backend,
    example
    ].join(" ")
    exec command

# The lexer and the config parsers need no driver, so they are tested directly.
exec "nim c -r tests/tinyniftest.nim"
exec "nim c -r tests/configtest.nim"
exec "nim c -r tests/markdowntest.nim"
# Bold and italics reach the drawing path through stub relays.
exec "nim c -r tests/styletest.nim"
# The word index needs no font until something draws with it.
exec "nim c -r tests/wordindextest.nim"
# The clipboard is a relay, so the test can hold the text itself.
exec "nim c -r tests/cliphistorytest.nim"
# Search and replace is a walk over a buffer; nothing there draws either.
exec "nim c -r tests/searchtest.nim"
# A highlighter's output is token classes, which are colorless until a theme
# gets them -- so the console one is tested without a window as well.
exec "nim c -r tests/consoletest.nim"
# Line wrapping is what the drawing path does with a line that is too long,
# so it is watched through the same stub relays as the font styles.
exec "nim c -r tests/wraptest.nim"
# Where the caret may go in a terminal, and what a key means where it stands.
exec "nim c -r tests/terminaltest.nim"
# And that the row the caret is on is the row that gets the band.
exec "nim c -r tests/activelinetest.nim"
# Everything around asking a compiler where a name is -- but not the compiler,
# which is not something a test may assume is installed.
exec "nim c -r tests/tracktest.nim"
# And what `open <name>` does with a name that is missing most of its path.
exec "nim c -r tests/filesearchtest.nim"
# That a rune of more than one byte is one character to every key that steps
# over it, and that a byte belonging to no rune stands for itself.
exec "nim c -r tests/utf8test.nim"

# The app, once, with the platform's default backend.
exec "nim c apps/focim.nim"

execBackend("")
when defined(features.uirelays.figDrawWindy):
  execBackend("--define:\"features.uirelays.figDrawWindy\"")
when defined(features.uirelays.figDrawSiwin):
  execBackend("--define:\"features.uirelays.figDrawSiwin\"")
when defined(linux):
  execBackend("-d:gtk4")
# execBackend("-d:sdl2")
# execBackend("-d:sdl3")
