import LeanAppNative.Notes
import LeanAppNative.Env
import LeanAppNative.Lifecycle

/-- Additive `migrate apply` for an existing volume before the runtime gate is consulted.
Refuses a destructive plan so a hosted instance never drops tables on boot. -/
private def ensureSchema (path : System.FilePath) (base : LeanDb.Base) : IO Unit := do
  unless ← path.pathExists do return
  match ← LeanDb.migrate path base.specs (apply := true) with
  | .error e => throw (IO.userError s!"notes schema migration failed: {e}")
  | .ok (some plan, _) =>
    if plan.isDestructive then
      throw (IO.userError "notes schema migration is destructive; refusing automatic apply")
  | .ok (none, _) => pure ()

def main : IO UInt32 := do
  let path := (← IO.getEnv "LEANAPP_DB_PATH").getD "/data/notes.sqlite"
  let some port := ((← IO.getEnv "LEANAPP_BACKEND_PORT").getD "4191").toNat?
    | throw (IO.userError "invalid backend port")
  if port == 0 || port > 65535 then throw (IO.userError "invalid backend port")
  let development := (← IO.getEnv "LEANAPP_DEVELOPMENT") == some "1"
  let origin := (← IO.getEnv "LEANAPP_ORIGIN").getD ""
  LeanAppNative.Log.configure (← LeanAppNative.Env.logConfig)
  let config := LeanDb.Instance.ofPath path
  ensureSchema path LeanAppNative.Notes.base
  let .ok session ← LeanDb.Cli.Session.open LeanAppNative.Notes.base config
    | throw (IO.userError "notes database unavailable")
  let runtime ← LeanDb.Runtime.Service.new LeanAppNative.Notes.base config session true
  try
    let .ok auth ← LeanAppNative.Auth.Service.new runtime (config := ← LeanAppNative.Env.authConfig)
      | throw (IO.userError "authentication unavailable")
    let host ← LeanAppNative.Notes.host auth origin development (← LeanAppNative.Env.maxConnections)
    Std.Async.Async.block do
      let server ← host.serve (.v4 ⟨Std.Net.IPv4Addr.ofParts 127 0 0 1, port.toUInt16⟩)
      server.waitShutdown
    return ← LeanAppNative.Lifecycle.shutdown runtime
  catch e =>
    IO.eprintln s!"notes: {e}"
    return ← LeanAppNative.Lifecycle.shutdown runtime
