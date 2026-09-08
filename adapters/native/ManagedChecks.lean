import LeanAppNative.Managed
import LeanDb.Derive

open LeanAppNative LeanApp Contract Ontology

namespace ManagedFixture

structure Item where
  value : String
  deriving Repr, LeanDb.Entity

namespace Changed
structure Item where
  value : String
  added : Option String
  deriving Repr, LeanDb.Entity
end Changed

def base : LeanDb.Base := { name := "managed_fixture", tables := [.of Item] }
def changedBase : LeanDb.Base := { base with tables := [.of Changed.Item] }

structure Ops where
  get : Operation .query Unit Nat String
  put : Operation .command Nat Nat String

def operations : Validation Ops := do
  return ⟨← Operation.canonical .query ⟨"managed", "get", "1"⟩,
    ← Operation.canonical .command ⟨"managed", "put", "1"⟩⟩

inductive ReadOp : Type → Type where
  | marker : ReadOp Nat
inductive WriteOp : Type → Type where
  | put (n : Nat) : WriteOp (Except String Nat)

structure Counters where
  policies : IO.Ref Nat
  handlers : IO.Ref Nat

def makeApp (ops : Ops) (counters : Counters) (read : IO Nat)
    (write : Nat → IO (Except String Nat)) : Validation (Application IO) := do
  let policy := fun (ctx : RequestContext) => do
    counters.policies.modify (· + 1)
    pure <| match ctx.principal with
      | none => Except.error (CallError.unauthenticated : CallError Empty)
      | some p => if p.tenant == "fixture" then .ok () else .error .forbidden
  let get : Binding IO ReadOp WriteOp ops.get := {
    http := { path := "/value" }
    policy := fun ctx _ _ => policy ctx
    handler := fun _ cap _ => do
      counters.handlers.modify (· + 1)
      return .ok (← cap.read .marker) }
  let put : Binding IO ReadOp WriteOp ops.put := {
    http := { path := "/put" }
    policy := fun ctx _ _ => policy ctx
    handler := fun _ cap n => do
      counters.handlers.modify (· + 1)
      cap.write (.put n) }
  let reads : ReadCapability IO ReadOp := { read := fun op => match op with | .marker => read }
  let writes : CommandCapability IO ReadOp WriteOp := {
    toRead := reads, write := fun op => match op with | .put n => write n }
  Application.create "fixture" [{ name := "fixture", exports := [
    get.approve (fun _ => reads), put.approve (fun _ => writes)] }]

def readMarker (conn : LeanDb.Conn) : IO Nat := do
  let stmt ← conn.raw.prepare "SELECT n FROM owned_marker"
  unless ← stmt.step do throw (IO.userError "missing connection marker")
  return (← stmt.columnInt64 0).toInt.toNat

def writeValue (conn : LeanDb.Conn) (release : IO.Promise (Except IO.Error Unit))
    (n : Nat) : IO (Except String Nat) := do
  if n == 900 then IO.ofExcept release.result!.get
  if n == 500 then throw (IO.userError "/private/database.sqlite: sensitive host error")
  -- Transactions are explicitly chosen by the handler, never by Managed.dispatch.
  match ← LeanDb.DbM.run conn (LeanDb.transaction do
      discard <| LeanDb.insert Item ⟨toString n⟩
      if n == 99 then return .abort "rejected"
      return .commit n) with
  | .ok result => return result
  | .error error => throw (IO.userError (toString error))

def context : RequestContext := TrustedNative.issueContext ⟨"local", "fixture", 0⟩ "fixture"

def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

def expect [ToString ε] (value : Except ε α) : IO α :=
  match value with | .ok a => pure a | .error e => throw (IO.userError (toString e))

def valid (value : Validation α) : IO α :=
  match value with | .ok a => pure a | .error e => throw (IO.userError (reprStr e))

def unavailable (reply : HttpReply) : Bool :=
  reply.status == 503 && reply.body == Http.protocolResponse "application.unavailable"
def failed (reply : HttpReply) : Bool :=
  reply.status == 500 && reply.body == Http.protocolResponse "application.failed"

def waitState (service : LeanDb.Runtime.Service) (p : LeanDb.Runtime.State → Bool) : IO Unit := do
  for _ in [:300] do
    if p (← service.snapshot) then return
    IO.sleep 10
  throw (IO.userError "state transition timeout")

def quick (action : IO HttpReply) : IO HttpReply := do
  let task ← IO.asTask action (prio := .dedicated)
  for _ in [:200] do
    if ← IO.hasFinished task then return ← IO.ofExcept task.get
    IO.sleep 5
  throw (IO.userError "public metadata/readiness blocked behind database work")

def rowCount (conn : LeanDb.Conn) : IO Nat := do
  let rows ← expect (← LeanDb.DbM.run conn (LeanDb.fetchAll Item))
  return rows.size

def run (dir : System.FilePath) : IO Unit := do
  let ops ← valid operations
  let codecs ← valid Http.codecs
  let counters : Counters := ⟨← IO.mkRef 0, ← IO.mkRef 0⟩
  let templateCalls ← IO.mkRef 0
  let templateApp ← valid (makeApp ops counters
    (do templateCalls.modify (· + 1); pure 0)
    (fun _ => do templateCalls.modify (· + 1); pure (.ok 0)))
  let config : ServerConfig := {
    errorStatuses := [Http.ErrorStatus.ofOperation ops.put (fun _ => 409)]
    maxBodyBytes := 512
    failureCode := "/private/config.sqlite: do not expose" }
  let template ← valid (Server.create templateApp codecs config)
  let release ← IO.Promise.new (α := Except IO.Error Unit)
  let factory := fun conn => makeApp ops counters (readMarker conn) (writeValue conn release)
  let inst := LeanDb.Instance.ofPath (dir / "owned.sqlite")
  let session ← expect (← LeanDb.Cli.Session.open base inst)
  let service ← LeanDb.Runtime.Service.new base inst session true
  let service := { service with maxPending := 2 }
  let managed ← valid (Managed.create service template factory)
  let getBody := (Http.encodeRequest codecs ⟨ops.get.identity, .query, .null⟩).compress
  let putBody := fun n => (Http.encodeRequest codecs ⟨ops.put.identity, .command, ops.put.inputCodec.encode n⟩).compress
  let put := fun n => managed.dispatch context "POST" "/put" (putBody n)
  let manifest ← managed.dispatch context "GET" "/api/manifest" ""
  try
    check "readiness starts ready" ((← managed.readiness).status == 200)
    let owned ← session.conn.get
    owned.raw.exec "CREATE TEMP TABLE owned_marker (n INTEGER); INSERT INTO owned_marker VALUES (37)"
    let reply ← managed.dispatch context "POST" "/value" getBody
    check "handler uses the real owned connection-local TEMP state"
      (reply.status == 200 && reply.body == Http.successResponse codecs ops.get.identity (Codec.nat.encode 37))
    check "policy and handler execute under admitted dispatch"
      ((← counters.policies.get) == 1 && (← counters.handlers.get) == 1 && (← service.snapshot).completed == 1)
    check "static template handlers are never executed" ((← templateCalls.get) == 0)
    check "command commits its explicit transaction" ((← put 8).status == 200 && (← rowCount owned) == 1)
    let rejected ← put 99
    check "domain rejection preserves status and rolls back explicit transaction"
      (rejected.status == 409 && rejected.body == Http.domainResponse codecs ops.put.identity (.str "rejected") &&
        (← rowCount owned) == 1)
    let before ← counters.handlers.get
    check "anonymous policy denial is 401" ((← managed.dispatch (.anonymous "anon") "POST" "/put" (putBody 1)).status == 401)
    let denied := TrustedNative.issueContext ⟨"local", "other", 0⟩ "denied"
    check "tenant policy denial is 403" ((← managed.dispatch denied "POST" "/put" (putBody 1)).status == 403)
    check "policy denial has no handler or command effect" ((← counters.handlers.get) == before && (← rowCount owned) == 1)
    check "known path wrong method keeps Server 405" ((← managed.dispatch context "GET" "/put" "").status == 405)
    check "malformed request keeps Server 400" ((← managed.dispatch context "POST" "/put" "{").status == 400)
    check "literal path remains literal" ((← managed.dispatch context "POST" "/%70ut" (putBody 1)).status == 404)
    check "bounded request keeps Server 413" ((← managed.dispatch context "POST" "/put" (String.ofList (List.replicate 513 'x'))).status == 413)
    check "no public raw CRUD or administration route" ((← managed.dispatch context "POST" "/rpc" "[\"runtime\",\"drain\"]").status == 404 && (← managed.readiness).status == 200)
    let badFactory ← valid (Managed.create service template (fun _ => Validation.fail "/private/factory.sqlite"))
    check "factory validation failure is sanitized 500" (failed (← badFactory.dispatch context "POST" "/put" (putBody 1)))
    let differentOps := { ops with get := ← valid (Operation.canonical .query ⟨"managed", "different", "1"⟩) }
    let drift ← valid (Managed.create service template (fun conn => makeApp differentOps counters (readMarker conn) (writeValue conn release)))
    check "factory metadata drift rejected before handlers" (failed (← drift.dispatch context "POST" "/put" (putBody 1)) && (← counters.handlers.get) == before)
    let empty ← valid (Application.create "empty" ([] : List (LeanApp.Module IO)))
    let missing ← valid (Managed.create service template (fun _ => .ok empty))
    check "factory missing exports rejected" (failed (← missing.dispatch context "POST" "/put" (putBody 1)))
    check "handler host exception sanitized despite template failureCode" (failed (← put 500))
    check "host failure releases runtime admission" ((← service.snapshot).active == 0 && (← service.snapshot).queued == 0)
    check "readiness path cannot shadow export" (!(Managed.create service template factory "/put").isOk)
    check "readiness path cannot shadow manifest" (!(Managed.create service template factory "/api/manifest").isOk)
    -- Model restore's connection-ref replacement while drained and holding the database lock.
    -- The owner remains the same; no application handler opens a second unmanaged connection.
    service.drain
    check "drain is sanitized 503 before factory validation" (unavailable (← badFactory.dispatch context "POST" "/put" (putBody 1)))
    service.database.atomically fun _ => do
      let replacement ← expect (← LeanDb.openDbRaw inst.path)
      replacement.raw.exec "CREATE TEMP TABLE owned_marker (n INTEGER); INSERT INTO owned_marker VALUES (73)"
      session.conn.set replacement
    discard <| service.resume
    let reply ← managed.dispatch context "POST" "/value" getBody
    check "fresh admitted factory observes replaced session connection"
      (reply.status == 200 && reply.body == Http.successResponse codecs ops.get.identity (Codec.nat.encode 73))
    check "old connection marker differs, ruling out stale capture" ((← readMarker owned) == 37)
    check "manifest remains frozen after connection replacement"
      ((← managed.dispatch context "GET" "/api/manifest" "").body == manifest.body)
    let held ← IO.asTask (put 900) (prio := .dedicated)
    waitState service (·.active == 1)
    let queued ← IO.asTask (put 10) (prio := .dedicated)
    waitState service (fun s => s.active == 1 && s.queued == 1)
    let before ← counters.handlers.get
    check "overload is sanitized 503" (unavailable (← quick (put 11)))
    check "readiness responds outside a full database queue" ((← quick managed.readiness).status == 200)
    check "public health route responds outside queue" ((← quick (managed.dispatch context "GET" "/health/ready" "")).status == 200)
    check "manifest responds outside a full database queue" ((← quick (managed.dispatch context "GET" "/api/manifest" "")).body == manifest.body)
    service.drain
    check "drain readiness is cheap and sanitized"
      ((← quick managed.readiness).body == .mkObj [("ok", .bool false), ("ready", .bool false)])
    check "drain rejects new commands before handlers" (unavailable (← quick (put 12)) && (← counters.handlers.get) == before)
    release.resolve (.ok ())
    check "previously admitted active work finishes after drain" ((← IO.ofExcept held.get).status == 200)
    check "previously admitted queued work finishes after drain" ((← IO.ofExcept queued.get).status == 200)
    check "commands used current session connection" ((← rowCount (← session.conn.get)) == 3)
    check "admitted work leaves runtime idle" ((← service.snapshot).active == 0 && (← service.snapshot).queued == 0)
    service.close
    let before ← counters.handlers.get
    check "closed admission is sanitized 503" (unavailable (← put 13) && (← counters.handlers.get) == before)
    check "closed readiness is 503" ((← managed.readiness).status == 503)
    check "manifest stable after close" ((← managed.dispatch context "GET" "/api/manifest" "").body == manifest.body)
  finally
    release.resolve (.ok ())
    service.close
  let changed ← expect (← LeanDb.Cli.Session.open changedBase inst)
  let gatedService ← LeanDb.Runtime.Service.new changedBase inst changed true
  let gated ← valid (Managed.create gatedService template factory)
  try
    check "real schema mismatch established" ((← changed.gate.get).isSome)
    let before ← counters.policies.get
    check "schema gate is sanitized 503" (unavailable (← gated.dispatch context "POST" "/put" (putBody 3)))
    check "schema gate runs no policy" ((← counters.policies.get) == before)
    check "schema-gated readiness contains no DB diagnostics"
      ((← gated.readiness).status == 503 && (← gated.readiness).body == .mkObj [("ok", .bool false), ("ready", .bool false)])
  finally gatedService.close
  let inspection ← expect (← LeanDb.Cli.Session.inspect inst)
  let inspectService ← LeanDb.Runtime.Service.new changedBase inst inspection true
  let inspectManaged ← valid (Managed.create inspectService template factory)
  try
    check "inspection-only session cannot admit public work" (unavailable (← inspectManaged.dispatch context "POST" "/put" (putBody 3)))
    check "inspection-only session is publicly unready" ((← inspectManaged.readiness).status == 503)
  finally inspection.close
  IO.println "PASS managed application dispatch qualification (no listeners)"

end ManagedFixture

def main (args : List String) : IO Unit := do
  let [directory] := args | throw (IO.userError "usage: managed_checks <fresh-fixture-directory>")
  ManagedFixture.run directory
