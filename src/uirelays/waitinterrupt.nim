## Driver-side helper for `interruptWaitEvent`: one process-wide, sticky,
## coalescing "please return from waitEvent" flag. Not re-exported by
## `uirelays`; drivers import it directly.
##
## Protocol:
## - The interrupting thread calls `raiseInterrupt()`. Only when it returns
##   true (the flag went from clear to set) does the driver poke its native
##   event loop, so a burst of interrupts costs one native wakeup.
## - The UI thread calls `takeInterrupt()` before it blocks and after every
##   wakeup; a true result means waitEvent returns false right away.
##
## Because the flag is set before the native loop is poked and is checked
## before blocking, no interrupt can be lost. At worst a stale native wakeup
## makes one later wait return early, which waitEvent already allows.

import std/atomics

when defined(nimony):
  var pending: bool
  proc swapPending(v: bool): bool {.inline.} = atomicExchange(pending, v)
else:
  var pending: Atomic[bool]
  proc swapPending(v: bool): bool {.inline.} = pending.exchange(v)

proc raiseInterrupt*(): bool {.gcsafe.} =
  ## Sets the flag. True when it was clear, i.e. the native loop must be woken.
  when defined(nimony):
    result = not swapPending(true)
  else:
    {.cast(gcsafe).}:
      result = not swapPending(true)

proc takeInterrupt*(): bool =
  ## Consumes the flag. True when an interrupt was pending.
  result = swapPending(false)
