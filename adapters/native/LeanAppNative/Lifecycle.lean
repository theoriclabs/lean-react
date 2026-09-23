import LeanAppNative.Managed
import LeanAppNative.Auth.Http
import Std.Async.Signal

namespace LeanAppNative.Lifecycle

structure Options where
  drainTimeoutMs : Nat := 15000
  /-- After the drain deadline cancels in-flight exchanges, how long they get to unwind. -/
  cancelGraceMs : Nat := 2000
  deriving Repr

private def idleWithin (service : Runtime.Service) (ms : Nat) : IO Bool := do
  let deadline := (← IO.monoMsNow) + ms
  repeat
    let st ← service.snapshot
    if st.active == 0 && st.queued == 0 && st.readersActive == 0 then return true
    if (← IO.monoMsNow) ≥ deadline then return false
    IO.sleep 20
  return false

/-- Mark not-ready, wait for in-flight work, checkpoint and close the database, exit 0.
    At the drain deadline, `cancel` (the HTTP server's shutdown) aborts in-flight
    exchanges. If work is still active after `cancelGraceMs`, the database is left
    open for SQLite's crash recovery and the result is 1, so shutdown stays bounded. -/
def shutdown (service : Runtime.Service) (opts : Options := {}) (cancel : IO Unit := pure ()) :
    IO UInt32 := do
  service.drain (stopping := true)
  if ← idleWithin service opts.drainTimeoutMs then
    service.close
    return 0
  try cancel catch _ => pure ()
  if ← idleWithin service opts.cancelGraceMs then
    service.close
  return 1

/-- Block until SIGTERM or SIGINT, or until `server` stops on its own. -/
def waitForStop (server : Std.Http.Server) : Std.Async.Async Unit := do
  let term ← Std.Async.Signal.Waiter.mk .sigterm false
  let interrupt ← Std.Async.Signal.Waiter.mk .sigint false
  try
    Std.Async.Selectable.one #[
      .case term.selector (fun _ => pure ()),
      .case interrupt.selector (fun _ => pure ()),
      .case server.waitShutdownSelector (fun _ => pure ())]
  finally
    term.stop
    interrupt.stop

/-- Serve until SIGTERM/SIGINT, then `shutdown`, cancelling `server` at the drain deadline. -/
def serveUntilStopped (service : Runtime.Service) (serve : Std.Async.Async Std.Http.Server)
    (opts : Options := {}) : IO UInt32 := do
  let server ← Std.Async.Async.block do
    let server ← serve
    waitForStop server
    return server
  shutdown service opts (cancel := Std.Async.Async.block server.shutdown)

end LeanAppNative.Lifecycle
