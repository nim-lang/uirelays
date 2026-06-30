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

execBackend("")
when defined(linux):
  execBackend("-d:gtk4")
# execBackend("-d:sdl2")
# execBackend("-d:sdl3")
