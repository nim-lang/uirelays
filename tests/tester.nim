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

# The app, once, with the platform's default backend.
exec "nim c apps/focim.nim"

execBackend("")
when defined(feature.uirelays.figDrawWindy):
  execBackend("--define:\"feature.uirelays.figDrawWindy\"")
when defined(feature.uirelays.figDrawSiwin):
  execBackend("--define:\"feature.uirelays.figDrawSiwin\"")
when defined(linux):
  execBackend("-d:gtk4")
# execBackend("-d:sdl2")
# execBackend("-d:sdl3")
