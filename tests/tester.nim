import std/os

proc fatal(msg: string) = quit "FAILURE " & msg

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0: fatal cmd


template execBackend(cmd: string) =
  exec "nim c " & cmd & " examples/hello.nim"
  exec "nim c " & cmd & " examples/layout_demo.nim"
  exec "nim c " & cmd & " examples/paint.nim"
  exec "nim c " & cmd & " examples/todo.nim"


execBackend("")
# execBackend("-d:gtk4")
# execBackend("-d:sdl2")
# execBackend("-d:sdl3")
