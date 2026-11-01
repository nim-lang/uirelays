import std/[os, osproc, strutils]

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

# The lexer needs no driver, so it is tested directly.
exec "nim c -r tests/tinyniftest.nim"
# And so does the layout: dividing a rectangle, finding the borders in it, and
# moving one, are arithmetic that never touches a window.
exec "nim c -r tests/layouttest.nim"

exec "nim c -r tests/rgbatest.nim"
when defined(windows):
  exec "nim c -r tests/nativealphatest.nim"
  exec "nim c -r tests/rendertexttest.nim"
elif defined(linux):
  if findExe("xvfb-run").len > 0:
    exec "xvfb-run -a nim c -r tests/nativealphatest.nim"
    # Xft needs a display even for text that never reaches a window.
    exec "xvfb-run -a nim c -r tests/rendertexttest.nim"
  exec "nim c -r -d:gtk4 tests/rendertexttest.nim"
elif defined(macosx):
  exec "nim c -r tests/rendertexttest.nim"
when defined(macosx):
  let cocoaTest = getTempDir() / ("uirelays-cocoargbatest-" & $getCurrentProcessId())
  exec "clang -fobjc-arc tests/cocoargbatest.m -o " & quoteShell(cocoaTest) &
    " -framework Cocoa -framework CoreText -framework CoreGraphics -framework QuartzCore"
  exec quoteShell(cocoaTest)
  removeFile(cocoaTest)

when defined(linux) or defined(macosx):
  if findExe("pkg-config").len > 0 and execShellCmd("pkg-config --exists cairo") == 0:
    let cairoTest = getTempDir() / ("uirelays-cairorgbatest-" & $getCurrentProcessId())
    let cairoFlags = execProcess("pkg-config", args = ["--cflags", "--libs", "cairo"],
                                 options = {poUsePath}).strip()
    exec "cc tests/cairorgbatest.c -o " & quoteShell(cairoTest) & " " & cairoFlags
    exec quoteShell(cairoTest)
    removeFile(cairoTest)

# Everything else is a window, and a window is what the examples are: each
# backend gets to compile all of them.
execBackend("")
when defined(features.uirelays.figDrawWindy):
  execBackend("--define:\"features.uirelays.figDrawWindy\"")
when defined(features.uirelays.figDrawSiwin):
  exec "nim c -r tests/figdrawsiwinlooptest.nim"
  execBackend("--define:\"features.uirelays.figDrawSiwin\"")
elif defined(features.uirelays.siwin):
  execBackend("--define:\"features.uirelays.siwin\"")
when defined(uirelaysWindowTests):
  # Opt in on a real desktop, or run the tester inside xvfb-run on Linux.
  exec "nim c -r tests/siwinnativetest.nim"
when defined(linux):
  exec "nim c -r tests/gtkstatetest.nim"
  execBackend("-d:gtk4")
# execBackend("-d:sdl2")
# execBackend("-d:sdl3")
