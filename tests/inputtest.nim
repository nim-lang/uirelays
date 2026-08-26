## The rule every driver applies before it reports typed text: a chord that
## carries a command modifier is a command, not a character. Needs no window.

import uirelays/input

echo "command chords:"

var failures = 0

proc check(name: string; cond: bool) =
  if cond:
    echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name

check("plain typing is text", not isCommandChord({}))
check("shifted typing is text", not isCommandChord({ShiftPressed}))
check("Ctrl+'+' is a command", isCommandChord({CtrlPressed}))
check("Ctrl+Shift+'+' too", isCommandChord({CtrlPressed, ShiftPressed}))
check("Cmd+'+' as well", isCommandChord({GuiPressed}))
check("and Cmd+Shift", isCommandChord({GuiPressed, ShiftPressed}))
# AltGr is Ctrl+Alt on a PC keyboard, and a German layout types '@', '\' and
# '{' with it -- dropping that text would make those keys stop working.
check("AltGr stays text", not isCommandChord({CtrlPressed, AltPressed}))
check("AltGr with shift as well",
      not isCommandChord({CtrlPressed, AltPressed, ShiftPressed}))
# Option on macOS is the same story: ⌥n types a dead tilde.
check("Alt alone stays text", not isCommandChord({AltPressed}))
check("but Cmd wins over AltGr",
      isCommandChord({CtrlPressed, AltPressed, GuiPressed}))

echo(if failures == 0: "ALL PASS" else: $failures & " FAILURE(S)")
if failures > 0: quit 1
