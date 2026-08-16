## Install desktop integration for a uirelays app.
##
##   nim c -r tools/install_desktop.nim <app-id> <exec> [icons]
##
## `app-id` is the icon name / StartupWMClass / CFBundle name stem -- it must
## match whatever the app passes to `setWindowClass`.
##
## `icons` is optional:
##   - a `hicolor` tree (…/hicolor/48x48/apps/<app-id>.png, …),
##   - a single PNG, or
##   - on macOS, a ready-made `.icns`
## If omitted, `<repo>/apps/icons/hicolor` is used when it already has
## `<app-id>.png` entries; else `<repo>/apps/<app-id>-icon.png`.
##
## Behaviour depends on the host OS:
##   Linux   -- FreeDesktop `.desktop` + icons under `~/.local/share`
##   macOS   -- builds `<Name>.app` (binary, Info.plist, AppIcon.icns)
##   Windows -- nothing to install; link a `.res` into the binary instead
##
## Optional flags (anywhere after the app-id):
##   --name <Name>             display name (default: app-id)
##   --generic-name <text>     Linux GenericName=
##   --comment <text>          Comment= / CFBundleGetInfoString
##   --categories <Cats>       Linux Categories= (default: Utility;)
##   --bundle-id <id>          macOS CFBundleIdentifier (default: org.uirelays.<app-id>)
##   --out <path>              macOS bundle path (default: ~/Applications/<Name>.app)

import std/[os, osproc, strutils, strformat]

# ---------------------------------------------------------------------------
# shared
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir

proc resolveExec(arg: string): string =
  if arg.len == 0:
    quit("missing <exec> path")
  if fileExists(arg) or symlinkExists(arg):
    return expandFilename(arg)
  let found = findExe(arg)
  if found.len > 0:
    return found
  quit("cannot find executable: " & arg)

proc defaultHicolor(appId: string): string =
  let root = repoRoot() / "apps" / "icons" / "hicolor"
  for path in walkDirRec(root):
    if path.extractFilename == appId & ".png":
      return root
  ""

proc defaultPng(appId: string): string =
  let p = repoRoot() / "apps" / (appId & "-icon.png")
  if fileExists(p): p else: ""

proc resolveIconSource(appId, iconsArg: string): string =
  ## Returns a hicolor dir, a PNG path, an ICNS path, or "".
  if iconsArg.len > 0:
    if dirExists(iconsArg) or fileExists(iconsArg):
      return iconsArg
    quit("icons path not found: " & iconsArg)
  result = defaultHicolor(appId)
  if result.len == 0:
    result = defaultPng(appId)

proc bestPngFromHicolor(hicolor, appId: string): string =
  ## Prefer the largest apps/<app-id>.png under a hicolor tree.
  var bestSize = -1
  for path in walkDirRec(hicolor):
    if path.extractFilename != appId & ".png": continue
    let parent = path.parentDir.parentDir.extractFilename # "256x256"
    let times = parent.find('x')
    if times <= 0: continue
    let n = parent[0 ..< times].parseInt
    if n > bestSize:
      bestSize = n
      result = path

proc sourcePng(appId, iconsArg: string): string =
  ## A single PNG suitable for resizing into an icon set.
  let src = resolveIconSource(appId, iconsArg)
  if src.len == 0:
    quit("no icons given and none found for " & appId)
  if fileExists(src) and src.endsWith(".png"):
    return src
  if fileExists(src) and src.endsWith(".icns"):
    return "" # caller handles icns
  if dirExists(src):
    let hicolor =
      if src.extractFilename == "hicolor": src
      elif dirExists(src / "hicolor"): src / "hicolor"
      else: src
    result = bestPngFromHicolor(hicolor, appId)
    if result.len == 0:
      quit("hicolor tree has no " & appId & ".png")
    return result
  quit("cannot derive a PNG from: " & src)

proc copyTree(src, dst: string) =
  for path in walkDirRec(src):
    let rel = path.relativePath(src)
    let target = dst / rel
    createDir(target.parentDir)
    copyFile(path, target)
    echo "  ", target

# ---------------------------------------------------------------------------
# Linux -- FreeDesktop
# ---------------------------------------------------------------------------

proc xdgDataHome(): string =
  getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")

proc desktopExec(path: string): string =
  if path.find({' ', '\t', '"', '\\', '$', '`'}) >= 0:
    '"' & path.replace("\\", "\\\\").replace("\"", "\\\"") & '"'
  else:
    path

proc installLinuxIcons(appId, iconsArg: string; dataHome: string) =
  let dest = dataHome / "icons" / "hicolor"
  var src = resolveIconSource(appId, iconsArg)
  if src.len == 0:
    quit("no icons given and none found under apps/icons/hicolor for " & appId)

  if dirExists(src):
    let hicolor =
      if src.extractFilename == "hicolor": src
      elif dirExists(src / "hicolor"): src / "hicolor"
      else: src
    echo "icons -> ", dest
    copyTree(hicolor, dest)
  elif fileExists(src) and src.endsWith(".png"):
    let target = dest / "256x256" / "apps" / (appId & ".png")
    createDir(target.parentDir)
    copyFile(src, target)
    echo "icons -> ", target
  else:
    quit("Linux install needs a PNG or hicolor tree, got: " & src)

proc writeDesktop(appId, execPath, name, genericName, comment, categories: string;
                  dataHome: string) =
  var body = "[Desktop Entry]\n"
  body.add "Type=Application\n"
  body.add "Version=1.0\n"
  body.add "Name=" & name & "\n"
  if genericName.len > 0:
    body.add "GenericName=" & genericName & "\n"
  if comment.len > 0:
    body.add "Comment=" & comment & "\n"
  body.add "Exec=" & desktopExec(execPath) & "\n"
  body.add "Icon=" & appId & "\n"
  body.add "Terminal=false\n"
  body.add "Categories=" & categories & "\n"
  body.add "StartupNotify=true\n"
  body.add "StartupWMClass=" & appId & "\n"

  let desktopPath = dataHome / "applications" / (appId & ".desktop")
  createDir(desktopPath.parentDir)
  writeFile(desktopPath, body)
  echo "desktop -> ", desktopPath
  echo "Exec=", execPath

proc installLinux(appId, execPath, iconsArg, name, genericName, comment,
                  categories: string) =
  let data = xdgDataHome()
  installLinuxIcons(appId, iconsArg, data)
  writeDesktop(appId, execPath, name, genericName, comment, categories, data)
  discard execCmd("update-desktop-database " & quoteShell(data / "applications") &
                  " >/dev/null 2>&1")
  discard execCmd("gtk-update-icon-cache -f -t " & quoteShell(data / "icons" / "hicolor") &
                  " >/dev/null 2>&1")

# ---------------------------------------------------------------------------
# macOS -- .app bundle
# ---------------------------------------------------------------------------

proc xmlEscape(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc writeInfoPlist(path, name, execName, bundleId, comment: string) =
  var s = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$EXEC</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
"""
  s = s.replace("$EXEC", xmlEscape(execName))
    .replace("$ID", xmlEscape(bundleId))
    .replace("$NAME", xmlEscape(name))
  if comment.len > 0:
    s.add "\t<key>CFBundleGetInfoString</key>\n"
    s.add "\t<string>" & xmlEscape(comment) & "</string>\n"
  s.add "</dict>\n</plist>\n"
  writeFile(path, s)

proc runOrQuit(cmd: string) =
  let code = execCmd(cmd)
  if code != 0:
    quit("command failed (" & $code & "): " & cmd)

proc buildIcns(pngPath, icnsPath: string) =
  ## Build AppIcon.icns from a PNG via `sips` + `iconutil` (macOS only).
  let iconset = icnsPath & ".iconset"
  if dirExists(iconset):
    removeDir(iconset)
  createDir(iconset)

  # (pixel size, iconutil filename)
  const entries = [
    (16, "icon_16x16.png"),
    (32, "diana.ar@example.org"),
    (32, "icon_32x32.png"),
    (64, "ivan.p@example.net"),
    (128, "icon_128x128.png"),
    (256, "wendy.h@example.net"),
    (256, "icon_256x256.png"),
    (512, "wendy.h@example.net"),
    (512, "icon_512x512.png"),
    (1024, "walt.e@example.net"),
  ]
  for (px, fname) in entries:
    let outPng = iconset / fname
    runOrQuit(&"sips -z {px} {px} {quoteShell(pngPath)} --out {quoteShell(outPng)} >/dev/null")

  runOrQuit(&"iconutil -c icns {quoteShell(iconset)} -o {quoteShell(icnsPath)}")
  removeDir(iconset)

proc installMacos(appId, execPath, iconsArg, name, comment, bundleId,
                  outArg: string) =
  let bundlePath =
    if outArg.len > 0: expandFilename(outArg)
    else: getHomeDir() / "Applications" / (name & ".app")

  if not bundlePath.endsWith(".app"):
    quit("--out must end in .app, got: " & bundlePath)

  let contents = bundlePath / "Contents"
  let macosDir = contents / "MacOS"
  let resources = contents / "Resources"
  createDir(macosDir)
  createDir(resources)

  let execName = appId
  let destBin = macosDir / execName
  copyFile(execPath, destBin)
  inclFilePermissions(destBin, {fpUserExec, fpGroupExec, fpOthersExec})
  echo "binary -> ", destBin

  let icnsPath = resources / "AppIcon.icns"
  let src = resolveIconSource(appId, iconsArg)
  if src.len > 0 and fileExists(src) and src.endsWith(".icns"):
    copyFile(src, icnsPath)
    echo "icon -> ", icnsPath, " (copied)"
  else:
    let png = sourcePng(appId, iconsArg)
    buildIcns(png, icnsPath)
    echo "icon -> ", icnsPath

  writeInfoPlist(contents / "Info.plist", name, execName, bundleId, comment)
  echo "plist -> ", contents / "Info.plist"
  echo "bundle -> ", bundlePath

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

proc usage() =
  stderr.write """usage: install_desktop <app-id> <exec> [icons] [options]

  --name <Name>
  --generic-name <text>     (Linux)
  --comment <text>
  --categories <Cats>       (Linux)
  --bundle-id <id>          (macOS, default org.uirelays.<app-id>)
  --out <path.app>          (macOS, default ~/Applications/<Name>.app)
"""
  quit(1)

proc main =
  var
    appId, execArg, iconsArg = ""
    name, genericName, comment = ""
    categories = "Utility;"
    bundleId, outArg = ""
    positional: seq[string]

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--name" and i < paramCount():
      inc i; name = paramStr(i)
    elif a == "--generic-name" and i < paramCount():
      inc i; genericName = paramStr(i)
    elif a == "--comment" and i < paramCount():
      inc i; comment = paramStr(i)
    elif a == "--categories" and i < paramCount():
      inc i; categories = paramStr(i)
    elif a == "--bundle-id" and i < paramCount():
      inc i; bundleId = paramStr(i)
    elif a == "--out" and i < paramCount():
      inc i; outArg = paramStr(i)
    elif a in ["-h", "--help"]:
      usage()
    elif a.startsWith("-"):
      quit("unknown option: " & a)
    else:
      positional.add a
    inc i

  if positional.len < 2 or positional.len > 3:
    usage()
  appId = positional[0]
  execArg = positional[1]
  if positional.len == 3:
    iconsArg = positional[2]
  if name.len == 0:
    name = appId
  if bundleId.len == 0:
    bundleId = "org.uirelays." & appId

  let execPath = resolveExec(execArg)

  case hostOS
  of "linux":
    installLinux(appId, execPath, iconsArg, name, genericName, comment, categories)
  of "macosx":
    installMacos(appId, execPath, iconsArg, name, comment, bundleId, outArg)
  of "windows":
    echo "Windows: embed a PE icon with windres + {.link: \"….res\".}; nothing to install."
  else:
    quit("unsupported host OS: " & hostOS)

  echo "done."

main()
