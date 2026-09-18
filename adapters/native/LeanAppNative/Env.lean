import LeanAppNative.Auth.Store

/-! Environment parsing for the application executables. The libraries take typed values only. -/
namespace LeanAppNative.Env

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

/-- A positive integer setting, or `default` when unset. -/
def natSetting (name : String) (default : Nat) (max : Nat := 1000000) : IO Nat := do
  match ← IO.getEnv name with
  | none | some "" => pure default
  | some value =>
    let some n := value.toNat? | throw (IO.userError s!"invalid {name}")
    if n == 0 || n > max then throw (IO.userError s!"invalid {name}")
    pure n

/-- Authentication service configuration assembled from the environment:
`LEANAPP_TENANT_POLICY` and `LEANAPP_MAX_SESSIONS` (concurrent sessions per account, default 1). -/
def authConfig : IO Auth.Service.Config := do
  return { tenantPolicy := ← tenantPolicy, maxSessions := ← natSetting "LEANAPP_MAX_SESSIONS" 1 100 }

end LeanAppNative.Env
