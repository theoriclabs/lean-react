import NativeTickets.Http
import NativeTickets.Client

namespace NativeTickets.Checks
open Ontology Contract Examples.Tickets Examples.Tickets.Contracts

def hugeRevision : Nat := 2^128 + 9007199254740993
def fixtureKey := "public-ticket-9007199254740993"

def check (condition : Bool) (label : String) : IO Unit :=
  unless condition do throw (IO.userError s!"FAIL: {label}")

def requireOk [Repr ε] (result : Except ε α) (label : String) : IO α :=
  match result with
  | .ok value => pure value
  | .error error => throw (IO.userError s!"FAIL: {label}: {repr error}")

private def fixture (tickets : Array TicketSummary) : IO TicketSummary :=
  match tickets.find? (fun ticket => ticket.id.key == fixtureKey) with
  | some ticket => pure ticket
  | none => throw (IO.userError "fixture ticket missing; initialize a fresh fixture database first")

def initializeFixture (path : System.FilePath) : IO Store := do
  if ← path.pathExists then throw (IO.userError "fixture database must not already exist")
  let store ← Store.open path
  let id ← requireOk (EntityId.parse "tickets-demo" fixtureKey) "fixture ID"
  let user ← requireOk (EntityId.parse (α := User) "directory-demo" "user-17") "fixture assignee"
  store.insertFixture ⟨id, hugeRevision, ⟨⟨"Native integration fixture"⟩, .backlog, some user⟩⟩
  pure store

def localTransport (ops : PublicOperations) (store : Store) : Transport IO :=
  match makeClient ops "http://127.0.0.1" with
  | .error errors => { send := fun _ => pure (.error (.decode errors)) }
  | .ok client => client.transportWith fun http => do
    let path := toString http.uri.path
    let body := match http.body with | .json json => json.compress | _ => ""
    let reply ← dispatch ops store (toString http.method) path body
    -- Exercise the actual LeanHttp success/status decoding paths without opening a socket.
    let response : LeanHttp.Response := {
      status := (Std.Http.Status.ofCode none reply.status.toUInt16).getD .internalServerError
      headers := .empty
      body := reply.body.compress.toUTF8
      effectiveUri := Std.Http.URI.parse! s!"http://127.0.0.1{path}" }
    pure (response.decodeAs (α := Lean.Json))

/-- The same checks drive the real SQLite dispatcher and the real LeanHttp transport. -/
def scenario (ops : PublicOperations) (transport : Transport IO) : IO Unit := do
  let interpreter := transport.interpreter
  let rows ← requireOk (← interpreter.call ops.list ()) "list"
  let current ← fixture rows
  check (current.revision == hugeRevision) "large revision persisted and transported exactly"
  let encoded := ops.codecs.summary.encode current
  let revision ← requireOk (encoded.getObjVal? "revision") "encoded revision"
  check (revision == Codec.nat.encode hugeRevision) "revision uses tagged decimal string"
  let input : SaveTicket := ⟨current.id, current.revision, ⟨"Saved with shared domain rules"⟩, .inProgress⟩
  let saved ← requireOk (← interpreter.call ops.save input) "save"
  check (saved.revision == hugeRevision + 1) "revision increments without narrowing"
  check (saved.value.title == input.title && saved.value.status == .inProgress) "saved public projection"
  check (saved.value.assignee == current.value.assignee) "saving retains the persisted assignee"
  match ← interpreter.call ops.save input with
  | .error (.domain (.conflict latest)) => check (latest == saved) "stale save preserves current persisted record"
  | _ => throw (IO.userError "FAIL: stale save must be a typed conflict")
  let missingId ← requireOk (EntityId.parse "tickets-demo" "missing-public-key") "missing ID"
  match ← interpreter.call ops.save { input with id := missingId } with
  | .error (.domain .notFound) => pure ()
  | _ => throw (IO.userError "FAIL: missing save must be typed notFound")
  let wrongScope ← requireOk (EntityId.parse "another-instance" current.id.key) "different scope"
  match ← interpreter.call ops.save { input with id := wrongScope } with
  | .error (.domain .notFound) => pure ()
  | _ => throw (IO.userError "FAIL: public scope must participate in lookup")
  match ← interpreter.call ops.save { input with title := ⟨""⟩ } with
  | .error (.decode errors) =>
    check (errors.first.code == "title.empty" && errors.first.path == [.key "title"]) "invalid input keeps field path"
  | _ => throw (IO.userError "FAIL: invalid title must be a decode error")
  let listRequest : WireRequest := ⟨ops.list.identity, .query, .null⟩
  match ← transport.send { listRequest with operation := { listRequest.operation with version := "old-client" } } with
  | .error (.incompatible mismatch) => check (mismatch.expected == ops.list.identity) "changed client contract rejected"
  | _ => throw (IO.userError "FAIL: changed client contract accepted")
  let saveJson := ops.codecs.saveInput.encode input
  let fields ← requireOk saveJson.getObj? "save fields"
  let badRevision := Lean.Json.obj (fields.insert "expectedRevision" (.num 9007199254740993))
  match ← transport.send ⟨ops.save.identity, .command, badRevision⟩ with
  | .error (.decode errors) => check (errors.first.path == [.key "expectedRevision"]) "numeric revision rejected"
  | _ => throw (IO.userError "FAIL: lossy numeric revision accepted")
  let userId ← requireOk (EntityId.parse (α := User) "tickets-demo" current.id.key) "nominal mismatch ID"
  let badId := Lean.Json.obj (fields.insert "id" (userIdCodec.encode userId))
  match ← transport.send ⟨ops.save.identity, .command, badId⟩ with
  | .error (.decode errors) => check (errors.first.code == "identity.type_mismatch") "nominal mismatch rejected"
  | _ => throw (IO.userError "FAIL: wrong entity reference accepted")
  let latest ← fixture (← requireOk (← interpreter.call ops.list ()) "list after errors")
  check (latest == saved) "rejected calls do not modify storage"
  IO.println "PASS list/save/stale/not-found/invalid/large-revision/contract-version/reference checks"

/-- Every role × operation × {anonymous, another tenant} through the real application transport.
The save probe names a missing ticket, so admitted callers receive the typed `notFound` unchanged. -/
def roleMatrix (ops : PublicOperations) (store : Store) : IO Unit := do
  let app ← requireOk (application ops store.service) "application"
  let missingId ← requireOk (EntityId.parse "tickets-demo" "matrix-probe") "probe ID"
  let probe : SaveTicket := ⟨missingId, 0, ⟨"Role matrix probe"⟩, .backlog⟩
  let cases := LeanApp.Testing.exhaustiveMatrix app [Role.viewer, .editor, .owner]
    (fun id => if id == listIdentity then some .viewer else if id == saveIdentity then some .editor else none)
    (fun id => if id == saveIdentity then ops.codecs.saveInput.encode probe else .null)
  let issue := fun (actor tenant : String) => LeanApp.TrustedNative.issueContext ⟨actor, tenant, 0⟩ "matrix"
  let contexts : LeanApp.Testing.Fixture Role := { context := fun
    | .anonymous => .anonymous "matrix"
    | .role .owner | .owner => localFixtureContext
    | .role .editor => issue "fixture-editor" localTenant
    | .role .viewer => issue "fixture-viewer" localTenant
    | .otherTenant => issue "local-fixture" "another-tenant" }
  let failures ← LeanApp.Testing.runMatrix app contexts cases
  unless failures.isEmpty do throw (IO.userError s!"FAIL: role matrix\n{LeanApp.Testing.report failures}")
  check (cases.size == 10) "matrix covers 3 roles × 2 operations × {anonymous, other tenant}"
  check (approvedMetadata ops == ops.approved) "bindings publish the portable contract's HTTP metadata"
  IO.println "PASS role matrix over the native application"

def native (path : System.FilePath) : IO Unit := do
  let ops ← loadOperations
  let store ← initializeFixture path
  roleMatrix ops store
  scenario ops (localTransport ops store)
  let second ← Store.open path
  let before ← fixture (← second.list)
  check (before.revision == hugeRevision + 1) "a newly opened connection reads persisted save"
  let input : SaveTicket := ⟨before.id, before.revision, ⟨"Concurrent save"⟩, .done⟩
  let firstTask ← IO.asTask (store.save input) (prio := .dedicated)
  let secondTask ← IO.asTask (second.save input) (prio := .dedicated)
  let first ← IO.ofExcept firstTask.get
  let secondResult ← IO.ofExcept secondTask.get
  let results := [first, secondResult]
  check ((results.filter (fun result => result.isOk)).length == 1) "concurrent connections have one winner"
  check ((results.filter (fun result => match result with
    | .error (.conflict latest) => latest.revision == before.revision + 1
    | _ => false)).length == 1) "concurrent loser sees persisted winner"
  let unknown ← dispatch ops store "POST" "/rpc" "[\"delete\"]"
  check (unknown.status == 404) "no arbitrary database argv route"
  let malformed ← dispatch ops store "POST" "/api/tickets/list" "{"
  check (malformed.status == 400) "malformed JSON rejected"
  let wrongMethod ← dispatch ops store "GET" "/api/tickets/save" ""
  check (wrongMethod.status == 405) "method policy enforced"
  let manifest ← dispatch ops store "GET" "/api/manifest" ""
  check (manifest.status == 200 && manifest.body == ops.manifest) "explicit public manifest"
  let reopened ← Store.open path
  let persisted ← fixture (← reopened.list)
  check (persisted.revision == hugeRevision + 2) "concurrent result persisted exactly"
  IO.println "PASS SQLite persistence, separate public IDs, serialized concurrent writers, allowlist, and manifest"

def http (port : UInt16) : IO Unit := do
  let ops ← loadOperations
  let transport := clientTransport ops port
  scenario ops transport
  let current ← fixture (← requireOk (← transport.interpreter.call ops.list ()) "HTTP list")
  let input : SaveTicket := ⟨current.id, hugeRevision, current.value.title, current.value.status⟩
  let request : WireRequest := ⟨ops.save.identity, .command, ops.codecs.saveInput.encode input⟩
  let outcome : LeanHttp.Outcome Lean.Json ← LeanHttp.requestAs {
    method := .post, uri := .absolute (Std.Http.URI.parse! s!"http://127.0.0.1:{port}/api/tickets/save"),
    body := .json (encodeRequest ops request), redirects := .never,
    timeouts := { connect := .ofNat 2000, total := .ofNat 5000 } }
  match outcome with
  | .status response => check (response.statusCode == 409) "LeanHttp reports raw domain-error status"
  | _ => throw (IO.userError "FAIL: expected LeanHttp.Outcome.status for stale save")
  match decodeOutcome ops request outcome with
  | .ok (.domainError body) =>
    match ops.codecs.saveError.decode body with
    | .ok (.conflict latest) => check (latest == current) "409 body decodes structured conflict"
    | _ => throw (IO.userError "FAIL: conflict payload missing")
  | _ => throw (IO.userError "FAIL: HTTP status response was not decoded")
  IO.println "PASS actual LeanHttp local request and non-2xx domain-error decoding"

end NativeTickets.Checks
