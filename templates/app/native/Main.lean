import {{Name}}Native.Application
import LeanAppNative.Env
import LeanAppNative.Lifecycle

/-- Additive `migrate apply` for an existing volume before the runtime gate is consulted.
Refuses a destructive plan so a hosted instance never drops tables on boot. -/
private def ensureSchema (path : System.FilePath) (base : LeanDb.Base) : IO Unit := do
  unless ← path.pathExists do return
  match ← LeanDb.migrate path base.specs (apply := true) with
  | .error e => throw (IO.userError s!"{{name}} schema migration failed: {e}")
  | .ok (some plan, _) =>
    if plan.isDestructive then
      throw (IO.userError "{{name}} schema migration is destructive; refusing automatic apply")
  | .ok (none, _) => pure ()

/-- Environment: `LEANAPP_DB_PATH`, `LEANAPP_BACKEND_PORT` (loopback), `LEANAPP_ORIGIN`,
`LEANAPP_DEVELOPMENT`, `LEANAPP_DB_READERS`, `LEANAPP_SERIALIZE_REQUESTS`, `LEANAPP_TENANT_POLICY`,
`LEANAPP_MAX_SESSIONS`, `LEANAPP_SESSION_CACHE_TTL_MS`, `LEANAPP_BACKEND_MAX_CONNECTIONS`, `LEANAPP_LOG*`. -/
def main : IO UInt32 := do
  let path := (← IO.getEnv "LEANAPP_DB_PATH").getD "/data/{{name}}.sqlite"
  let some port := ((← IO.getEnv "LEANAPP_BACKEND_PORT").getD "4271").toNat?
    | throw (IO.userError "invalid backend port")
  if port == 0 || port > 65535 then throw (IO.userError "invalid backend port")
  let development := (← IO.getEnv "LEANAPP_DEVELOPMENT") == some "1"
  let origin := (← IO.getEnv "LEANAPP_ORIGIN").getD ""
  LeanAppNative.Log.configure (← LeanAppNative.Env.logConfig)
  let inst := LeanDb.Instance.ofPath path
  ensureSchema path {{Name}}Native.base
  let .ok runtime ← LeanAppNative.Runtime.Service.new {{Name}}Native.base inst
      (config := ← LeanAppNative.Env.runtimeConfig)
    | throw (IO.userError "{{name}} database unavailable")
  try
    let .ok auth ← LeanAppNative.Auth.Service.new runtime (config := ← LeanAppNative.Env.authConfig)
      | throw (IO.userError "authentication unavailable")
    let host ← {{Name}}Native.host auth origin development (← LeanAppNative.Env.maxConnections)
      (serializeRequests := ← LeanAppNative.Env.serializeRequests)
    Std.Async.Async.block do
      let server ← host.serve (.v4 ⟨Std.Net.IPv4Addr.ofParts 127 0 0 1, port.toUInt16⟩)
      server.waitShutdown
    return ← LeanAppNative.Lifecycle.shutdown runtime
  catch e =>
    IO.eprintln s!"{{name}}: {e}"
    return ← LeanAppNative.Lifecycle.shutdown runtime
