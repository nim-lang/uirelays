## interruptWaitEvent: sticky, coalescing, and callable from another thread.
## Opens a real window, so run it where the backend can display one:
##   nim r --path:src tests/tinterruptwait.nim
##   Linux: xvfb-run -a nim r --path:src tests/tinterruptwait.nim

import std/[os, typedthreads]
import uirelays

proc drain() =
  var e = default Event
  while pollEvent(e): discard

proc waitMs(timeoutMs: int): int =
  ## Blocks in waitEvent until it returns false; real window events that
  ## arrive meanwhile are skipped. Returns the elapsed milliseconds.
  let t0 = getTicks()
  var e = default Event
  while waitEvent(e, timeoutMs): discard
  getTicks() - t0

proc worker(delayMs: int) {.thread.} =
  os.sleep(delayMs)
  interruptWaitEvent()

proc main =
  discard createWindow(240, 120)
  drain()

  # Sticky: an interrupt raised before waiting ends the next wait at once,
  # and repeated interrupts coalesce into one.
  interruptWaitEvent()
  interruptWaitEvent()
  doAssert waitMs(5000) < 1000, "pending interrupt was not seen"
  doAssert waitMs(300) >= 250, "coalesced interrupts woke more than one wait"

  # Cross-thread: an unbounded wait returns once another thread interrupts.
  var th: Thread[int]
  createThread(th, worker, 200)
  let dt = waitMs(-1)
  joinThread(th)
  doAssert dt >= 150 and dt < 2000, "cross-thread wake took " & $dt & "ms"

  # A finite wait is cut short as well.
  createThread(th, worker, 200)
  let dt2 = waitMs(5000)
  joinThread(th)
  doAssert dt2 >= 150 and dt2 < 2000, "finite wait took " & $dt2 & "ms"

  shutdown()
  echo "interruptWaitEvent: OK"

main()
