import LeanAppNative.Auth.Store

/-! Environment parsing for the application executables. The libraries take typed values only. -/
namespace LeanAppNative.Env

/-- Request logging: one JSON line per request to stderr by default, to `LEANAPP_LOG_FILE` when
set, or nothing with `LEANAPP_LOG=off`. `LEANAPP_LOG_ERRORS=verbose` adds exception messages. -/
def logConfig : IO Log.Config := do
  let sink ← match ← IO.getEnv "LEANAPP_LOG", ← IO.getEnv "LEANAPP_LOG_FILE" with
    | some "off", _ => pure Log.Sink.none
    | _, some path => if path.isEmpty then pure .stderr else pure (.file path)
    | _, none => pure .stderr
  return { sink, verboseErrors := (← IO.getEnv "LEANAPP_LOG_ERRORS") == some "verbose" }

/-- `LEANAPP_TENANT_POLICY=private|fixed:<name>|invite`; unset means a private tenant per account. -/
def tenantPolicy : IO Auth.TenantPolicy := do
  match ← IO.getEnv "LEANAPP_TENANT_POLICY" with
  | none | some "" | some "private" => pure .privatePerAccount
  | some "invite" => pure .invite
  | some value =>
    unless value.startsWith "fixed:" do throw (IO.userError "invalid LEANAPP_TENANT_POLICY")
    let tenant := (value.drop "fixed:".length).toString
    if tenant.isEmpty || tenant.length > 64 then throw (IO.userError "invalid LEANAPP_TENANT_POLICY tenant")
    pure (.fixed tenant)

/-- An integer setting in `[min, max]`, or `default` when unset. -/
def natSetting (name : String) (default : Nat) (max : Nat := 1000000) (min : Nat := 1) : IO Nat := do
  match ← IO.getEnv name with
  | none | some "" => pure default
  | some value =>
    let some n := value.toNat? | throw (IO.userError s!"invalid {name}")
    if n < min || n > max then throw (IO.userError s!"invalid {name}")
    pure n

/-- `LEANAPP_BACKEND_MAX_CONNECTIONS`: simultaneous connections the Lean listener accepts (default 64). -/
def maxConnections : IO Nat := natSetting "LEANAPP_BACKEND_MAX_CONNECTIONS" 64 65535

/-- Authentication service configuration assembled from the environment: `LEANAPP_TENANT_POLICY`,
`LEANAPP_MAX_SESSIONS` (concurrent sessions per account, default 1) and
`LEANAPP_SESSION_CACHE_TTL_MS` (in-process session cache, default 0 = off, 30000 recommended). -/
def authConfig : IO Auth.Service.Config := do
  return {
    tenantPolicy := ← tenantPolicy
    maxSessions := ← natSetting "LEANAPP_MAX_SESSIONS" 1 100
    sessionCacheTtlMs := ← natSetting "LEANAPP_SESSION_CACHE_TTL_MS" 0 600000 0 }

end LeanAppNative.Env
