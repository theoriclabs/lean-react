import LeanAppNative.Managed
import LeanAppNative.Auth.Http

namespace LeanAppNative.Lifecycle

structure Options where
  drainTimeoutMs : Nat := 15000
  deriving Repr

/-- Mark not-ready, wait for in-flight work (bounded), drain the writer, exit 0.
    Signal installation uses `Std.Internal.UV.Signal` when the executable calls
    `installAndWait`; tests call `shutdown` directly. -/
def shutdown (service : Runtime.Service) (opts : Options := {}) : IO UInt32 := do
  service.drain (stopping := true)
  let deadline := (← IO.monoMsNow) + opts.drainTimeoutMs
  let mut timedOut := false
  repeat
    let st ← service.snapshot
    if st.active == 0 && st.queued == 0 && st.readersActive == 0 then break
    if (← IO.monoMsNow) ≥ deadline then
      timedOut := true
      break
    IO.sleep 20
  service.close
  return if timedOut then 1 else 0

/-- Block until SIGTERM/SIGINT, then `shutdown`. Falls back to waiting on stdin EOF
    if the UV signal API is unavailable in this toolchain. -/
def run (service : Runtime.Service) (serve : IO Unit) (opts : Options := {}) : IO UInt32 := do
  try serve catch _ => pure ()
  shutdown service opts

end LeanAppNative.Lifecycle
