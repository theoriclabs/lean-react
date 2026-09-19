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

/-- `put` writes only; with `readAfterWrite` it reads again after its write and answers that
value, which models a command that inspects its own effect (LA-07). -/
def makeApp (ops : Ops) (counters : Counters) (read : IO Nat)
    (write : Nat → IO (Except String Nat)) (readAfterWrite : Bool := false) : Validation (Application IO) := do
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
      match ← cap.write (.put n) with
      | .error e => return .error e
      | .ok v => if readAfterWrite then return .ok (← cap.toRead.read .marker) else return .ok v }
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

def openService (base : LeanDb.Base) (inst : LeanDb.Instance) (config : Runtime.Config := {})
    (mode : LeanDb.Runtime.SessionMode := .serve) : IO Runtime.Service := do
  match ← Runtime.Service.new base inst mode config with
  | .ok service => pure service
  | .error e => throw (IO.userError s!"open failed: {e.message}")

def waitState (service : Runtime.Service) (p : Runtime.State → Bool) : IO Unit := do
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

/-- A fresh raw connection on the instance file, so counts can be read while the service is drained. -/
def rowCountFile (path : System.FilePath) : IO Nat := do
  rowCount (← expect (← LeanDb.openDbRaw path))

/-- Trusted test capture of the writer connection: the checks model connection-local state. -/
def heldConn (service : Runtime.Service) : IO LeanDb.Conn := do
  match ← service.withConnection pure with
  | .ok conn => pure conn
  | .error e => throw (IO.userError s!"writer unavailable: {e}")

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
  let service ← openService base inst { maxPending := 2 }
  let managed ← valid (Managed.create service template factory)
  let getBody := (Http.encodeRequest codecs ⟨ops.get.identity, .query, .null⟩).compress
  let putBody := fun n => (Http.encodeRequest codecs ⟨ops.put.identity, .command, ops.put.inputCodec.encode n⟩).compress
  let put := fun n => managed.dispatch context "POST" "/put" (putBody n)
  let manifest ← managed.dispatch context "GET" "/api/manifest" ""
  try
    check "readiness starts ready" ((← managed.readiness).status == 200)
    let owned ← heldConn service
    owned.raw.exec "CREATE TEMP TABLE owned_marker (n INTEGER); INSERT INTO owned_marker VALUES (37)"
    let reply ← managed.dispatch context "POST" "/value" getBody
    check "handler uses the real owned connection-local TEMP state"
      (reply.status == 200 && reply.body == Http.successResponse codecs ops.get.identity (Codec.nat.encode 37))
    check "policy and handler execute under admitted dispatch"
      ((← counters.policies.get) == 1 && (← counters.handlers.get) == 1 && (← service.snapshot).completed == 2)
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
    let lines ← IO.mkRef (#[] : Array String)
    Log.configure { sink := .buffer lines }
    check "handler host exception sanitized despite template failureCode" (failed (← put 500))
    Log.configure {}
    let events := (← lines.get).toList.filterMap fun line => (Lean.Json.parse line).toOption
    let text := fun (json : Lean.Json) (name : String) => ((json.getObjVal? name).bind (·.getStr?)).toOption
    check "caught exception is logged as an event with class and code, without the message"
      (events.length == 1 && text events[0]! "event" == some "error" && text events[0]! "component" == some "server" &&
        text events[0]! "class" == some "userError" && text events[0]! "code" == some "application.failed" &&
        text events[0]! "message" == none && !(String.intercalate "\n" (← lines.get).toList).contains "sensitive host error")
    let trace ← IO.mkRef ({} : Log.Trace)
    check "a traced dispatch records the operation, outcome and phases"
      ((← managed.dispatch context "POST" "/value" getBody (some trace)).status == 200 &&
        (← trace.get).operation == some ops.get.identity && (← trace.get).outcome == some .success &&
        (← trace.get).principalHash == some (Log.principalHash "local"))
    check "host failure releases runtime admission" ((← service.snapshot).active == 0 && (← service.snapshot).queued == 0)
    check "readiness path cannot shadow export" (!(Managed.create service template factory "/put").isOk)
    check "readiness path cannot shadow manifest" (!(Managed.create service template factory "/api/manifest").isOk)
    -- Model a restore: LeanDB swaps the instance file with a validated source and the runtime
    -- reopens the writer and every reader. No application handler ever opens its own connection.
    let source := dir / "restore-source.sqlite"
    discard <| service.withConnection fun conn => LeanDb.backupTo conn source
    service.drain
    check "drain is sanitized 503 before factory validation" (unavailable (← badFactory.dispatch context "POST" "/put" (putBody 1)))
    check "restore swaps the instance while drained" (← service.restore source).isOk
    check "resume readmits after a restore" (← service.resume)
    discard <| service.withConnection fun conn =>
      conn.raw.exec "CREATE TEMP TABLE owned_marker (n INTEGER); INSERT INTO owned_marker VALUES (73)"
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
    check "commands used current session connection" ((← rowCountFile inst.path) == 3)
    check "admitted work leaves runtime idle" ((← service.snapshot).active == 0 && (← service.snapshot).queued == 0)
    service.close
    let before ← counters.handlers.get
    check "closed admission is sanitized 503" (unavailable (← put 13) && (← counters.handlers.get) == before)
    check "closed readiness is 503" ((← managed.readiness).status == 503)
    check "manifest stable after close" ((← managed.dispatch context "GET" "/api/manifest" "").body == manifest.body)
  finally
    release.resolve (.ok ())
    service.close
  let gatedService ← openService changedBase inst
  let gated ← valid (Managed.create gatedService template factory)
  try
    check "real schema mismatch established" ((← gatedService.gate).isSome)
    let before ← counters.policies.get
    check "schema gate is sanitized 503" (unavailable (← gated.dispatch context "POST" "/put" (putBody 3)))
    check "schema gate runs no policy" ((← counters.policies.get) == before)
    check "schema-gated readiness contains no DB diagnostics"
      ((← gated.readiness).status == 503 && (← gated.readiness).body == .mkObj [("ok", .bool false), ("ready", .bool false)])
  finally gatedService.close
  let inspectService ← openService changedBase inst {} .inspect
  let inspectManaged ← valid (Managed.create inspectService template factory)
  try
    check "inspection-only session cannot admit public work" (unavailable (← inspectManaged.dispatch context "POST" "/put" (putBody 3)))
    check "inspection-only session is publicly unready" ((← inspectManaged.readiness).status == 503)
  finally inspectService.close
  -- LA-08: AppState survives requests; invalidate on restore; afterCommit skips abort.
  let invalidations ← IO.mkRef (0 : Nat)
  let state ← AppState.new (pure (0 : Nat)) (fun _ => do invalidations.modify (· + 1); pure 0)
  let inst2 := LeanDb.Instance.ofPath (dir / "state.sqlite")
  let service2 ← openService base inst2
  let managed2 ← valid (Managed.createWithState service2 template state
    (fun _st conn => makeApp ops counters (readMarker conn) (writeValue conn release)))
  try
    for _ in [:8] do
      discard <| managed2.dispatch context "POST" "/put" (putBody 1)
    check "app state survives repeated requests" ((← AppState.get state) ≥ 0)
    managed2.restored
    check "restore invalidates state once" ((← invalidations.get) == 1)
    let committed ← IO.mkRef false
    let aborted ← IO.mkRef false
    let conn2 ← heldConn service2
    discard <| LeanDb.DbM.run conn2 (state.transaction (ε := String) (α := Unit) do
      discard <| LeanDb.insert Item ⟨"committed"⟩
      AppState.afterCommit state (committed.set true)
      return .commit ())
    discard <| LeanDb.DbM.run conn2 (state.transaction (ε := String) (α := Unit) do
      AppState.afterCommit state (aborted.set true)
      return .abort "no")
    check "afterCommit runs only on commit" ((← committed.get) && !(← aborted.get))
  finally service2.close
  IO.println "PASS managed application dispatch qualification (no listeners)"

/-- LA-07: with a `lanes` factory, queries read on the pool while commands hold the writer for
one call; a request's reads after its first write go to the writer. -/
def lanes (dir : System.FilePath) : IO Unit := do
  let ops ← valid operations
  let codecs ← valid Http.codecs
  let counters : Counters := ⟨← IO.mkRef 0, ← IO.mkRef 0⟩
  let templateApp ← valid (makeApp ops counters (pure 0) (fun _ => pure (.ok 0)))
  let config : ServerConfig := {
    errorStatuses := [Http.ErrorStatus.ofOperation ops.put (fun _ => 409)], maxBodyBytes := 512 }
  let template ← valid (Server.create templateApp codecs config)
  let inst := LeanDb.Instance.ofPath (dir / "lanes.sqlite")
  let service ← openService base inst { readers := 2 }
  let release ← IO.Promise.new (α := Except IO.Error Unit)
  release.resolve (.ok ())
  let gate ← IO.mkRef (none : Option (IO.Promise (Except IO.Error Unit)))
  let factory := fun (caps : Capabilities) => makeApp ops counters
    (caps.reader fun conn => do
      if let some pending ← gate.get then IO.ofExcept pending.result!.get
      rowCount conn)
    (fun n => caps.writer fun conn => writeValue conn release n)
    (readAfterWrite := true)
  let managed ← valid (Managed.createWith service template factory)
  let getBody := (Http.encodeRequest codecs ⟨ops.get.identity, .query, .null⟩).compress
  let putBody := fun n => (Http.encodeRequest codecs ⟨ops.put.identity, .command, ops.put.inputCodec.encode n⟩).compress
  let put := fun (m : Managed) (n : Nat) => m.dispatch context "POST" "/put" (putBody n)
  let get := managed.dispatch context "POST" "/value" getBody
  let success := fun (n : Nat) => Http.successResponse codecs ops.get.identity (Codec.nat.encode n)
  try
    let first ← get
    let st ← service.snapshot
    check "lanes: a query reads on a pooled reader, never the writer"
      (first.status == 200 && first.body == success 0 && st.readersCompleted == 1 && st.completed == 0)
    let written ← put managed 1
    let st ← service.snapshot
    check "lanes: a command's post-write read goes to the writer and sees its own insert"
      (written.status == 200 && written.body == Http.successResponse codecs ops.put.identity (Codec.nat.encode 1) &&
        st.completed == 2 && st.readersCompleted == 1)
    check "lanes: a later query on a reader observes the committed row" ((← get).body == success 1)
    let slow ← IO.Promise.new (α := Except IO.Error Unit)
    gate.set (some slow)
    let reading ← IO.asTask get (prio := .dedicated)
    waitState service (·.readersActive == 1)
    gate.set none
    let started ← IO.monoMsNow
    let concurrent ← put managed 2
    let elapsed := (← IO.monoMsNow) - started
    slow.resolve (.ok ())
    check "lanes: a slow query does not delay a concurrent command's write"
      (concurrent.status == 200 && elapsed < 150 && (← IO.ofExcept reading.get).status == 200)
    let serial ← valid (Managed.createWith service template factory (serializeRequests := true))
    let before ← service.snapshot
    let reply ← put serial 3
    let st ← service.snapshot
    check "lanes: serializeRequests runs the whole request under one writer admission"
      (reply.status == 200 && st.completed == before.completed + 1 && st.readersCompleted == before.readersCompleted)
    let handlers ← counters.handlers.get
    service.drain
    check "lanes: drain is 503 before the factory or any handler"
      (unavailable (← put managed 4) && (← counters.handlers.get) == handlers)
    check "lanes: resume readmits" (← service.resume)
    let sabotaged ← valid (Managed.createWith service template fun caps => makeApp ops counters
      (do service.drain; caps.reader rowCount) (fun n => caps.writer fun conn => writeValue conn release n))
    let trace ← IO.mkRef ({} : Log.Trace)
    check "lanes: a refusal inside the handler is 503 unavailable, not a sanitized 500"
      (unavailable (← sabotaged.dispatch context "POST" "/value" getBody (some trace)) &&
        (← trace.get).outcome == some .unavailable)
    check "lanes: resume after the mid-request drain" (← service.resume)
    let trace ← IO.mkRef ({} : Log.Trace)
    let started ← IO.monoMsNow
    check "lanes: request phases stay disjoint" ((← managed.dispatch context "POST" "/value" getBody (some trace)).status == 200 &&
      (let t := (← trace.get).timings; t.auth + t.queueWait + t.db + t.handler ≤ (← IO.monoMsNow) - started + 1))
  finally service.close
  IO.println "PASS LA-07 lanes qualification"

/-- 8 clients, 70 % queries / 30 % commands, on a writer-only runtime and on one with four
pooled readers. Queries decode 2,000 rows so they carry real work. -/
def load (dir : System.FilePath) : IO Unit := do
  let ops ← valid operations
  let codecs ← valid Http.codecs
  let counters : Counters := ⟨← IO.mkRef 0, ← IO.mkRef 0⟩
  let templateApp ← valid (makeApp ops counters (pure 0) (fun _ => pure (.ok 0)))
  let template ← valid (Server.create templateApp codecs { maxBodyBytes := 512 })
  let getBody := (Http.encodeRequest codecs ⟨ops.get.identity, .query, .null⟩).compress
  let putBody := (Http.encodeRequest codecs ⟨ops.put.identity, .command, ops.put.inputCodec.encode 1⟩).compress
  let release ← IO.Promise.new (α := Except IO.Error Unit)
  release.resolve (.ok ())
  let spawn := fun (name : String) (readers : Nat) => do
    let service ← openService base (LeanDb.Instance.ofPath (dir / s!"load-{name}.sqlite")) { readers }
    discard <| service.withConnection fun conn => LeanDb.DbM.run conn (LeanDb.withTransaction do
      for i in [:2000] do discard <| LeanDb.insert Item ⟨toString i⟩)
    let managed ← valid (Managed.createWith service template fun caps => makeApp ops counters
      (caps.reader rowCount) (fun n => caps.writer fun conn => writeValue conn release n))
    pure (service, managed)
  let workload := fun (managed : Managed) => do
    let latencies ← IO.mkRef (#[] : Array Nat)
    let started ← IO.monoMsNow
    let tasks ← (List.range 8).mapM fun client => IO.asTask (prio := .dedicated) do
      for i in [:100] do
        if (client + i) % 10 < 7 then
          discard <| managed.dispatch context "POST" "/value" getBody
        else
          let t0 ← IO.monoMsNow
          discard <| managed.dispatch context "POST" "/put" putBody
          latencies.modify (·.push ((← IO.monoMsNow) - t0))
    for task in tasks do IO.ofExcept task.get
    let total := (← IO.monoMsNow) - started
    let sorted := (← latencies.get).qsort (· < ·)
    pure (total, sorted[sorted.size * 95 / 100]?.getD 0)
  let (serialService, serial) ← spawn "serial" 0
  let (pooledService, pooled) ← spawn "pooled" 4
  try
    let (serialMs, serialP95) ← workload serial
    let (pooledMs, pooledP95) ← workload pooled
    let ratio := serialMs * 100 / max pooledMs 1
    IO.println s!"load: readers=0 {serialMs} ms (p95 command {serialP95} ms); readers=4 {pooledMs} ms (p95 command {pooledP95} ms); throughput {ratio}% of serialized"
    check "lanes: four readers at least double throughput and do not worsen command p95" (ratio ≥ 200 && pooledP95 ≤ serialP95)
  finally
    serialService.close
    pooledService.close

end ManagedFixture

def main (args : List String) : IO Unit := do
  let [directory] := args | throw (IO.userError "usage: managed_checks <fresh-fixture-directory>")
  ManagedFixture.run directory
  ManagedFixture.lanes directory
  ManagedFixture.load directory
