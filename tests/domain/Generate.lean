import tests.domain.Browser
import tests.domain.PostViews
import LeanContract.Generate
import LeanApp.Domain.Memory
open LeanApp.Domain Contract

run_meta do
  IO.FS.createDirAll "tests/domain/generated"
  LeanJS.writeModule "tests/domain/generated/domain.mjs"
    #[`DomainBrowser.parseCase, `DomainBrowser.inputs, `DomainBrowser.results,
      `DomainBrowser.guestView, `DomainBrowser.hostParser,
      `DomainBrowser.hostForm, `DomainBrowser.partyComponent, `DomainBrowser.partyComponentWithRequests,
      `DomainBrowser.hostRaw, `DomainBrowser.parseHost, `DomainBrowser.hostFormView,
      `DomainBrowser.signUpView, `DomainBrowser.scalarEditors, `DomainBrowser.partyRef, `DomainBrowser.personRef, `DomainBrowser.pageOutput,
      `DomainBrowser.renamedFormView, `DomainBrowser.signInView, `DomainBrowser.dateDraft, `DomainBrowser.dateDisplay, `Contract.Browser.jsonObject,
      `Contract.Browser.jsonEntries, `Contract.Browser.jsonNumber, `Contract.Browser.frameworkError, `Contract.Browser.decodeErrors]
    (LeanReact.Compiler.options "../../../engine/adapters/leanjs-react.mjs")

-- DDD-LR-06: the post's pages, compiled; and a client for the post's `api` with its routes.
run_meta do
  LeanJS.writeModule "tests/domain/generated/post-app.mjs"
    #[`PostViews.appComponent, `PostViews.appProps, `PostViews.shellProps,
      `Contract.Browser.jsonObject, `Contract.Browser.jsonEntries, `Contract.Browser.jsonNumber,
      `Contract.Browser.frameworkError, `Contract.Browser.decodeErrors]
    (LeanReact.Compiler.options "../../../engine/adapters/leanjs-react.mjs")

private def publicOp (op : Contract.Operation k I O E) : LeanApp.PublicOperation × Contract.Http.ErrorStatus :=
  ({ operation := op.describe, http := { path := "/api/partiful/" ++ op.identity.name }, metadata := {} },
    Contract.Http.ErrorStatus.ofOperation op (fun _ => 422))

private def checked [Repr E] (result : Except E A) : IO A :=
  match result with | .ok value => pure value | .error error => throw (IO.userError (reprStr error))

/-- Real domain interpreter cases, then the actual derived public codec. -/
private def visibilityMatrix : IO Lean.Json := do
  let clock ← checked (Instant.ofEpochSeconds 100)
  let mut store : Memory.Store := { now := clock }
  let mut people : List (Row Unit Partiful.Person) := []
  for (name, email) in [("Host Alice", "alice@example.test"), ("Guest Bob", "bob@example.test"), ("Outside Carol", "carol@example.test")] do
    let value : Partiful.Person := ⟨← checked (Name.parse name), ← checked (Email.parse email)⟩
    let (ref, next) ← checked (Memory.command (Flow.create value : Flow .command Unit Partiful.host.Error _) store)
    store := next
    let ref ← checked ref
    let (row, _) ← checked ((Memory.lookup (Scope := Unit) ref).run store)
    let some row := row | throw (IO.userError "seeded matrix person missing")
    people := people ++ [row]
  let some alice := people[0]? | throw (IO.userError "Alice missing")
  let some bob := people[1]? | throw (IO.userError "Bob missing")
  let some carol := people[2]? | throw (IO.userError "Carol missing")
  let mut cases := []
  for visibility in [Partiful.GuestListVisibility.public, .attendees, .private] do
    let (created, partyStore) ← checked (Memory.command (Partiful.host.body (Trusted.signedIn alice)
      ⟨← checked (Title.parse "Matrix party"), ← checked (Instant.ofEpochSeconds 200), ← checked (Text.parse ""), visibility⟩) store)
    let party ← checked created
    let (included, partyStore) ← checked (Memory.command (Partiful.rsvp.body (Trusted.signedIn bob) ⟨party⟩) partyStore)
    let _ ← checked included
    for (label, live) in [("anonymous", none), ("host-without-rsvp", some alice), ("attendee", some bob), ("outsider", some carol)] do
      let (result, after) ← checked (Memory.read (Partiful.partyPage.body (Trusted.viewer live) ⟨party⟩) partyStore)
      let output ← checked result
      cases := cases ++ [Lean.Json.mkObj [
        ("visibility", Ontology.Wire.codec.encode visibility), ("actorLabel", .str label),
        ("actor", live.map (fun row => Ontology.Wire.codec.encode row.id) |>.getD .null),
        ("reference", Ontology.Wire.codec.encode party),
        ("value", Ontology.Wire.codec.encode output),
        ("projectionReads", .num (after.projectionReads - partyStore.projectionReads))]]
  return .arr cases.toArray

def main : IO Unit := do
  let codecs ← match Contract.Http.codecs with | .ok value => pure value | .error _ => throw (IO.userError "HTTP codec fixture")
  let published := [publicOp Partiful.account.signUp.contract,
    publicOp Partiful.account.signIn.contract, publicOp Partiful.host.contract,
    publicOp Partiful.rsvp.contract, publicOp Partiful.edit.contract,
    publicOp Partiful.reschedule.contract, publicOp Partiful.cancel.contract,
    publicOp Partiful.partyPage.contract]
  Contract.Generate.emitClient (published.map Prod.fst) codecs (published.map Prod.snd) "tests/domain/generated"
    "../../../engine/LeanContract"
  -- The post's api: decision-5 envelope over its own routes (`/parties/:party/rsvp`).
  let postRoutes : List Contract.Generate.ClientRoute := api.map fun endpoint =>
    { identity := endpoint.identity, method := endpoint.method.name, path := endpoint.path,
      params := endpoint.endpoint.pathParams }
  let postOps := api.map fun endpoint =>
    (({ operation := endpoint.describe, http := { path := endpoint.path }, metadata := {} } : LeanApp.PublicOperation),
      Contract.Http.ErrorStatus.ofOperation endpoint.endpoint.operation.contract (fun _ => 422))
  Contract.Generate.emitClient (postOps.map Prod.fst) codecs (postOps.map Prod.snd) "tests/domain/generated/post"
    "../../../../engine/LeanContract" (routes := postRoutes)
  IO.FS.writeFile "tests/domain/generated/matrix.json" (← visibilityMatrix).compress
  IO.FS.writeFile "tests/domain/generated/scalars.json"
    ((Ontology.Codec.list Ontology.Codec.string).encode DomainBrowser.results).compress
  let variants := (Ontology.Codec.list (Ontology.Wire.codec (α := Partiful.GuestListVisibility))).encode [.public, .attendees, .private]
  let name ← match Name.parse "Alice" with | .ok name => pure name | .error _ => throw (IO.userError "fixture name")
  let disclosure := disclosureCodec (Ontology.Wire.codec (α := List Partiful.Guest))
  IO.FS.writeFile "tests/domain/generated/wire.json" (Lean.Json.mkObj [
    ("variants", variants), ("hidden", disclosure.encode .hidden),
    ("empty", disclosure.encode (.visible [])), ("visible", disclosure.encode (.visible [⟨name⟩]))]).compress
