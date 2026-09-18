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

/-- Authentication service configuration assembled from the environment. -/
def authConfig : IO Auth.Service.Config := do
  return { tenantPolicy := ← tenantPolicy }

end LeanAppNative.Env
