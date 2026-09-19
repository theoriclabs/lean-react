import {{Name}}Native.Storage

namespace {{Name}}Native
open LeanApp Contract Ontology {{Name}}

inductive Read : Type → Type where
  | notes : Read (Array Note)

inductive Write : Type → Type where
  | add (title : Title) : Write (Except String Note)

private def performWrite (conn : LeanDb.Conn) (p : Principal) : {α : Type} → Write α → IO α
  | _, .add title => addNote conn p title

/-- Every operation requires a signed-in principal (`Policy.authenticated`); reads run on the
reader lane and each write holds the writer for its one transaction (LA-07). With `lanes := none`
the handlers are inert: that assembly only publishes the manifest. -/
private def applicationFor (lanes : Option LeanAppNative.Capabilities) : Validation (Application IO) := do
  let listOp : Operation .query Unit (Array Note) String ← Operation.canonical .query listIdentity
  let addOp : Operation .command Title Note String ← Operation.canonical .command addIdentity
  let listBinding : Binding IO Read Write listOp := { Policy.authenticated with
    http := { path := listPath }
    handler := fun _ cap _ => return .ok (← cap.read .notes) }
  let addBinding : Binding IO Read Write addOp := { Policy.authenticated with
    http := { path := addPath }
    handler := fun _ cap title => cap.write (.add title) }
  let read := fun (context : RequestContext) => {
    read := fun .notes => do
      let some caps := lanes | throw (IO.userError "inert template")
      let some p := context.principal | throw (IO.userError "unauthenticated")
      caps.reader fun conn => listNotes conn p : ReadCapability IO Read }
  let write := fun (context : RequestContext) => {
    toRead := read context
    write := fun {α} (request : Write α) => do
      let some caps := lanes | throw (IO.userError "inert template")
      let some p := context.principal | throw (IO.userError "unauthenticated")
      caps.writer fun conn => performWrite conn p request : CommandCapability IO Read Write }
  Application.create "{{name}}" [{ name := "notes", exports := [
    listBinding.approve read, addBinding.approve write] }]

def applicationWith (caps : LeanAppNative.Capabilities) := applicationFor (some caps)

/-- Shared by the host and the generated browser client (`GenerateClient.lean`). -/
def publicOperations : Validation (List PublicOperation) := (applicationFor none).map Application.manifest

def errorStatuses : Validation (List Http.ErrorStatus) := do
  let addOp : Operation .command Title Note String ← Operation.canonical .command addIdentity
  pure [Http.ErrorStatus.ofOperation addOp (fun _ => 422)]

def host (auth : LeanAppNative.Auth.Service) (origin : String) (development : Bool := false)
    (maxConnections : Nat := 64) (serializeRequests : Bool := false) : IO LeanAppNative.Auth.Host := do
  let .ok codecs := Http.codecs | throw (IO.userError "invalid codecs")
  let .ok app := applicationFor none | throw (IO.userError "invalid {{name}} application")
  let .ok statuses := errorStatuses | throw (IO.userError "invalid error statuses")
  let .ok template := LeanAppNative.Server.create app codecs {
    maxBodyBytes := 8192, errorStatuses := statuses, maxConnections }
    | throw (IO.userError "invalid server")
  let .ok host := LeanAppNative.Auth.Host.createWith auth template applicationWith origin development serializeRequests
    | throw (IO.userError "invalid authentication origin/configuration")
  pure host

end {{Name}}Native
