import LeanAppNative.Auth.Demo
import LeanAppNative.Env
import LeanAppNative.Lifecycle

/-- Additive `migrate apply` for an existing demo DB before the runtime gate is consulted. -/
private def ensureSchema (path : System.FilePath) (base : LeanDb.Base) : IO Unit := do
  unless ← path.pathExists do return
  match ← LeanDb.migrate path base.specs (apply := true) with
  | .error e => throw (IO.userError s!"auth schema migration failed: {e}")
  | .ok (some plan, _) =>
    if plan.isDestructive then
      throw (IO.userError "auth schema migration is destructive; refusing automatic apply")
  | .ok (none, _) => pure ()

def main (args : List String) : IO UInt32 := do
  let [port, path, origin] := args
    | IO.eprintln "usage: leanapp_auth_demo <loopback-port> <sqlite-file> <http://127.0.0.1:browser-port>"; return 2
  let some port := port.toNat? | throw (IO.userError "invalid port")
  if port == 0 || port > 65535 then throw (IO.userError "invalid port")
  LeanAppNative.Log.configure (← LeanAppNative.Env.logConfig)
  ensureSchema path LeanAppNative.Auth.Demo.base
  let .ok session ← LeanDb.Cli.Session.open LeanAppNative.Auth.Demo.base (LeanDb.Instance.ofPath path)
    | throw (IO.userError "authentication database unavailable")
  let runtime ← LeanDb.Runtime.Service.new LeanAppNative.Auth.Demo.base (LeanDb.Instance.ofPath path) session true
  try
    let .ok auth ← LeanAppNative.Auth.Service.new runtime (config := ← LeanAppNative.Env.authConfig)
      | throw (IO.userError "authentication initialization failed")
    let host ← LeanAppNative.Auth.Demo.host auth origin true (← LeanAppNative.Env.maxConnections)
    Std.Async.Async.block do
      let server ← host.serve (.v4 ⟨Std.Net.IPv4Addr.ofParts 127 0 0 1, port.toUInt16⟩)
      server.waitShutdown
    return ← LeanAppNative.Lifecycle.shutdown runtime
  catch e =>
    IO.eprintln s!"auth: {e}"
    return ← LeanAppNative.Lifecycle.shutdown runtime
