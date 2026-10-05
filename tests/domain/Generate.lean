/- Writes the compiled browser fixtures and the data the browser tests read:
   - `generated/domain.mjs`: LeanJS for `DomainBrowser` (forms, parsers) and `PostViews` (the app);
   - `generated/post/`: the generated client for the post's `api` (its routes, decision-5 envelope);
   - `generated/{matrix,scalars,wire}.json`: real in-memory outputs and codec bytes. -/
import tests.domain.Browser
import LeanContract.Generate
import LeanApi.Core.Memory
open LeanDb.Model LeanApi.Core Ontology

run_meta do
  IO.FS.createDirAll "tests/domain/generated"
  LeanJS.writeModule "tests/domain/generated/domain.mjs"
    #[`DomainBrowser.parseCase, `DomainBrowser.inputs, `DomainBrowser.results,
      `DomainBrowser.dateDraft, `DomainBrowser.dateDisplay,
      `DomainBrowser.guestView, `DomainBrowser.hostParser, `DomainBrowser.hostRaw, `DomainBrowser.parseHost,
      `DomainBrowser.hostForm, `DomainBrowser.hostFormView, `DomainBrowser.signUpView, `DomainBrowser.signInView,
      `DomainBrowser.scalarEditors, `DomainBrowser.settingsFormView, `DomainBrowser.partyRef, `DomainBrowser.personRef,
      `DomainBrowser.appWithRequests, `PostViews.appComponent, `PostViews.appProps, `PostViews.shellProps,
      `Contract.Browser.jsonObject, `Contract.Browser.jsonEntries, `Contract.Browser.jsonNumber,
      `Contract.Browser.frameworkError, `Contract.Browser.decodeErrors]
    (LeanReact.Compiler.options "../../../engine/adapters/leanjs-react.mjs")

private def checked [Repr E] (result : Except E A) : IO A :=
  match result with | .ok value => pure value | .error error => throw (IO.userError (reprStr error))
private def parsed (value : Validation A) : IO A :=
  match value with | .ok value => pure value | .error _ => throw (IO.userError "fixture value rejected")

deriving instance Repr for CreatePersonError
deriving instance Repr for HostError
deriving instance Repr for RsvpError
deriving instance Repr for GetPartyError

/-- Every visibility × viewer row of `getParty`, run in memory, then its public wire value. -/
private def visibilityMatrix : IO Lean.Json := do
  let mut store : LeanApi.Memory.Store := { now := ← parsed (Instant.ofEpochSeconds 100) }
  let mut people : List SignedIn := []
  for (name, email) in [("Host Alice", "alice@example.test"), ("Guest Bob", "bob@example.test"), ("Outside Carol", "carol@example.test")] do
    let (created, next) ← checked (LeanApi.Memory.command
      (createPerson (← parsed (Name.parse name)) (← parsed (Email.parse email)) : Flow .command OpScope _ _) store)
    store := next
    let ref ← checked created
    let (row, _) ← checked ((LeanApi.Memory.lookup (Scope := OpScope) ref).run store)
    let some row := row | throw (IO.userError "seeded person missing")
    people := people ++ [Principal.trusted row.id row.value]
  let some alice := people[0]? | throw (IO.userError "Alice missing")
  let some bob := people[1]? | throw (IO.userError "Bob missing")
  let some carol := people[2]? | throw (IO.userError "Carol missing")
  let mut cases := []
  for visibility in [GuestListVisibility.everyone, .attendees, .hostOnly] do
    let (created, partyStore) ← checked (LeanApi.Memory.command (hostParty alice (← parsed (Title.parse "Matrix party"))
      (← parsed (Text.parse "")) (← parsed (Instant.ofEpochSeconds 200)) visibility : Flow .command OpScope _ _) store)
    let party ← checked created
    let (going, partyStore) ← checked (LeanApi.Memory.command (rsvp bob party : Flow .command OpScope _ _) partyStore)
    let _ ← checked going
    for (label, viewer) in [("anonymous", none), ("host", some alice), ("attendee", some bob), ("outsider", some carol)] do
      let (result, after) ← checked (LeanApi.Memory.read (getParty viewer party : Flow .query OpScope _ _) partyStore)
      let page ← checked result
      cases := cases ++ [Lean.Json.mkObj [
        ("visibility", Wire.codec.encode visibility), ("actorLabel", .str label),
        ("actor", viewer.map (fun me => Wire.codec.encode me.id) |>.getD .null),
        ("reference", Wire.codec.encode party),
        ("value", Wire.codec.encode page),
        ("projectionReads", .num (after.storage.projectionReads - partyStore.storage.projectionReads))]]
  return .arr cases.toArray

def main : IO Unit := do
  let codecs ← match Contract.Http.codecs with | .ok value => pure value | .error _ => throw (IO.userError "HTTP codec fixture")
  -- The post's api: the decision-5 envelope over its own routes (`/parties/:party/rsvp`).
  let routes : List Contract.Generate.ClientRoute := api.map fun endpoint =>
    { identity := endpoint.identity, method := endpoint.method.name, path := endpoint.path,
      params := endpoint.endpoint.pathParams }
  let operations := api.map fun endpoint =>
    (({ operation := endpoint.describe, http := { path := endpoint.path }, metadata := {} } : LeanApi.Publication.PublicOperation),
      Contract.Http.ErrorStatus.ofOperation endpoint.endpoint.operation.contract (fun _ => 422))
  -- The JS runtime of the generated client is LeanAPI's (`LeanContract/{Fetch,Codecs}.mjs`).
  Contract.Generate.emitClient (operations.map Prod.fst) codecs (operations.map Prod.snd) "tests/domain/generated/post"
    "../../../../../leanapi/LeanContract" (routes := routes)
  IO.FS.writeFile "tests/domain/generated/matrix.json" (← visibilityMatrix).compress
  IO.FS.writeFile "tests/domain/generated/scalars.json"
    ((Codec.list Codec.string).encode DomainBrowser.results).compress
  let name ← parsed (Name.parse "Alice")
  let guests := Wire.codec (α := GuestList)
  IO.FS.writeFile "tests/domain/generated/wire.json" (Lean.Json.mkObj [
    ("variants", (Codec.list (Wire.codec (α := GuestListVisibility))).encode [.everyone, .attendees, .hostOnly]),
    ("hidden", guests.encode .hidden), ("empty", guests.encode (.visible [])),
    ("visible", guests.encode (.visible [⟨name⟩]))]).compress
