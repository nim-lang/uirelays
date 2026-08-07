import std/os

proc fatal(msg: string) = quit "FAILURE " & msg

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0: fatal cmd


template execBackend(cmd: string) =
  exec "nim c " & cmd & " examples/hello.nim"
  exec "nim c " & cmd & " examples/layout_demo.nim"
  exec "nim c " & cmd & " examples/paint.nim"
  exec "nim c " & cmd & " examples/todo.nim"


# The lexer and the config parsers need no driver, so they are tested directly.
exec "nim c -r tests/tinyniftest.nim"
exec "nim c -r tests/configtest.nim"

execBackend("")
when defined(feature.uirelays.figDrawWindy):
  execBackend("--define:\"feature.uirelays.figDrawWindy\"")
when defined(feature.uirelays.figDrawSiwin):
  execBackend("--define:\"feature.uirelays.figDrawSiwin\"")
when defined(linux):
  execBackend("-d:gtk4")
# execBackend("-d:sdl2")
# execBackend("-d:sdl3")
