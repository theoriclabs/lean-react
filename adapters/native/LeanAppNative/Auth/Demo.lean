import LeanAppNative.Auth.Http

namespace LeanAppNative.Auth.Demo
open LeanApp Contract Ontology LeanDb

def base : Base := { name := "leanapp_auth_demo", tables := Auth.tables }

inductive Read : Type → Type where
  | username : Read String
inductive Write : Type → Type

private def applicationFor (readName : RequestContext → IO String) : Validation (Application IO) := do
  let op : Operation .query Unit String String ← Operation.canonical .query ⟨"auth-demo", "whoami", "1"⟩
  let binding : Binding IO Read Write op := {
    http := { path := "/api/whoami" }
    policy := fun context _ _ => pure <| if context.principal.isSome then .ok () else .error .unauthenticated
    handler := fun _ cap _ => return .ok (← cap.read .username) }
  Application.create "auth-demo" [{ name := "profile", exports := [binding.approve fun context => {
    read := fun .username => readName context }] }]

private def profile (conn : Conn) (principal : Principal) : IO String := do
  let .ok rows ← DbM.run conn (selectP [Account] (.eq (.here Account.Field.actor) .eq principal.actor))
    | throw (IO.userError "profile unavailable")
  let some row := rows[0]? | throw (IO.userError "profile unavailable")
  if row.val.tenant != principal.tenant || !row.val.enabled then throw (IO.userError "profile unavailable")
  pure row.val.username

def application (conn : Conn) : Validation (Application IO) := applicationFor fun context => do
  let some principal := context.principal | throw (IO.userError "authentication required")
  profile conn principal

/-- LA-07 assembly: the profile read runs on the reader lane. -/
def applicationWith (caps : Capabilities) : Validation (Application IO) := applicationFor fun context => do
  let some principal := context.principal | throw (IO.userError "authentication required")
  caps.reader fun conn => profile conn principal

/-- The template has inert handlers. Auth.Host retains only its metadata/configuration. -/
def host (service : Auth.Service) (origin : String) (development : Bool := false)
    (maxConnections : Nat := 64) (serializeRequests : Bool := false) : IO Auth.Host := do
  let .ok codecs := Http.codecs | throw (IO.userError "invalid codecs")
  let .ok app := applicationFor (fun _ => throw (IO.userError "template is not executable"))
    | throw (IO.userError "invalid application")
  let .ok template := LeanAppNative.Server.create app codecs { maxBodyBytes := 8192, maxConnections }
    | throw (IO.userError "invalid server")
  let .ok host := Auth.Host.createWith service template applicationWith origin development serializeRequests
    | throw (IO.userError "invalid authentication origin/configuration")
  pure host

end LeanAppNative.Auth.Demo
