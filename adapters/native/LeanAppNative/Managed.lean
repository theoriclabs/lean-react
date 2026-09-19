import LeanAppNative.Server
import LeanAppNative.State
import LeanAppNative.Capabilities

namespace LeanAppNative
open LeanApp Contract Ontology

/-- A validated server supplies frozen public metadata, codecs and HTTP policy. Its application
and handlers are not retained, so a template closure cannot keep an old database handle alive.
Each admitted call constructs fresh handlers from the current lanes or connection. The trusted
factory must not retain a connection or launch work using it later. This adapter provides
admission and serialization, not an implicit transaction or authentication. -/
structure Managed where
  private mk ::
  private service : Runtime.Service
  private approved : List PublicOperation
  private codecs : Http.Codecs
  private config : ServerConfig
  private factory : Factory
  /-- With a `lanes` factory, still run each request under the writer (today's behaviour). -/
  private serializeRequests : Bool
  private publicBody : Lean.Json
  readinessPath : String
  private onInvalidate : IO Unit
  private onDrainConn : LeanDb.Conn → IO Unit

private def frozen (template : Server) (readinessPath : String) : Validation Server := do
  -- Host exception codes are adapter-owned; do not publish a caller's diagnostic string.
  let template ← Server.create template.app template.codecs
    { template.config with failureCode := "application.failed" }
  HttpBinding.validate { path := readinessPath }
  if readinessPath == template.config.manifestPath ||
      template.app.manifest.any (·.http.path == readinessPath) then
    Validation.fail "managed.readiness_path_collision"
  pure template

/-- Today's serialized path: `factory conn` runs under the writer for the whole request. -/
def Managed.create (service : Runtime.Service) (template : Server)
    (factory : LeanDb.Conn → Validation (Application IO))
    (readinessPath : String := "/health/ready")
    (onInvalidate : IO Unit := pure ())
    (onDrain : LeanDb.Conn → IO Unit := fun _ => pure ()) : Validation Managed :=
  match frozen template readinessPath with
  | .error errors => .error errors
  | .ok template => .ok ⟨service, template.app.manifest, template.codecs, template.config,
      .serialized factory, true, template.config.manifest template.app.manifest, readinessPath,
      onInvalidate, onDrain⟩

/-- LA-07: the factory receives request-scoped lanes. Body parsing, wire decoding, identity
checks, assembly and revalidation run outside any connection; the policy's reads and a query
handler's reads use the reader pool; a command handler's `write` holds the writer for that one
call, and its reads after the first write go to the writer. `serializeRequests := true`
(or `readers := 0` on the runtime) reproduces the serialized behaviour. -/
def Managed.createWith (service : Runtime.Service) (template : Server)
    (factory : Capabilities → Validation (Application IO))
    (readinessPath : String := "/health/ready")
    (serializeRequests : Bool := false)
    (onInvalidate : IO Unit := pure ())
    (onDrain : LeanDb.Conn → IO Unit := fun _ => pure ()) : Validation Managed :=
  match frozen template readinessPath with
  | .error errors => .error errors
  | .ok template => .ok ⟨service, template.app.manifest, template.codecs, template.config,
      .lanes factory, serializeRequests, template.config.manifest template.app.manifest, readinessPath,
      onInvalidate, onDrain⟩

/-- Factory may capture `AppState` (never `Conn`). Restore runs `AppState.invalidate`. -/
def Managed.createWithState {σ} (service : Runtime.Service) (template : Server)
    (state : AppState σ)
    (factory : AppState σ → LeanDb.Conn → Validation (Application IO))
    (readinessPath : String := "/health/ready")
    (onDrain : σ → LeanDb.Conn → IO Unit := fun _ _ => pure ()) : Validation Managed :=
  Managed.create service template (factory state) readinessPath
    (onInvalidate := state.invalidate)
    (onDrain := fun conn => do onDrain (← state.get) conn)

/-- Run `onInvalidate` then resume admission after a connection replacement. -/
def Managed.restored (managed : Managed) : IO Unit := do
  managed.onInvalidate
  discard managed.service.resume

/-- Flush `onDrain` under the writer, then stop admission. -/
def Managed.shutdown (managed : Managed) : IO Unit := do
  discard <| managed.service.withConnection fun conn => managed.onDrainConn conn
  managed.service.drain

private def unavailable : HttpReply := ⟨503, Http.protocolResponse "application.unavailable"⟩
private def failed : HttpReply := ⟨500, Http.protocolResponse "application.failed"⟩

/-- Do not expose runtime status, which contains instance paths and database diagnostics.
Readiness takes only the small runtime state lock, never the database queue. Inspection-only
sessions are unready by construction. -/
def Managed.readiness (managed : Managed) : IO HttpReply := do
  try
    let ready ← managed.service.ready
    return ⟨if ready then 200 else 503, .mkObj [("ok", .bool ready), ("ready", .bool ready)]⟩
  catch _ => return failed

/-- Assemble and revalidate the application for one request against the frozen template. The
factory cannot substitute HTTP/status/codec configuration. -/
private def Managed.server (managed : Managed) (app : Validation (Application IO)) : Option Server := do
  let .ok app := app | none
  if app.manifest != managed.approved then none
  (Server.create app managed.codecs managed.config).toOption

private def Managed.serializedDispatch (managed : Managed)
    (assemble : LeanDb.Conn → Validation (Application IO)) (context : RequestContext)
    (method path body : String) (trace : Log.TraceRef) : IO HttpReply := do
  let queued ← IO.monoMsNow
  let result ← managed.service.withConnection fun conn => do
    let entered ← IO.monoMsNow
    trace.phase (fun t n => { t with queueWait := t.queueWait + n }) queued
    let assembled := fun (outcome : IO HttpReply) => do
      trace.phase (fun t n => { t with db := t.db + n }) entered
      outcome
    let some server := managed.server (assemble conn) | assembled (return failed)
    -- Server catches handler exceptions using the fixed sanitized failure code. Declared
    -- domain responses (including their explicit status choices) remain unchanged.
    assembled (server.dispatch context method path body trace)
  match result with
  | .ok reply => return reply
  | .error (.host e) =>
    trace.failure "managed" "application.failed" e
    return failed
  | .error _ =>
    trace.update fun t => { t with outcome := some .unavailable }
    return unavailable

private def Managed.lanesDispatch (managed : Managed)
    (assemble : Capabilities → Validation (Application IO)) (context : RequestContext)
    (method path body : String) (trace : Log.TraceRef) : IO HttpReply := do
  -- Denied admission never reaches the factory or a handler. A refusal that lands mid-request
  -- (drain between this check and a lane call) is answered 503 by `Server.dispatch`.
  unless ← managed.service.ready do
    trace.update fun t => { t with outcome := some .unavailable }
    return unavailable
  let clock ← LaneClock.new
  let some server := managed.server (assemble (Capabilities.request managed.service clock)) | return failed
  let reply ← server.dispatch context method path body trace
  clock.settle trace
  return reply

/-- A static manifest remains available during drain/restore/closure and cannot drift with
the connection factory. No argv or admin entry point is provided. Denied admission never
invokes the factory or an application handler. -/
def Managed.dispatch (managed : Managed) (context : RequestContext)
    (method path body : String) (trace : Log.TraceRef := none) : IO HttpReply := do
  if path == managed.readinessPath then
    if method != "GET" then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
    return ← managed.readiness
  if path == managed.config.manifestPath then
    if method != "GET" then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
    return ⟨200, managed.publicBody⟩
  try
    match managed.factory with
    | .serialized assemble => managed.serializedDispatch assemble context method path body trace
    | .lanes assemble =>
      if managed.serializeRequests then
        managed.serializedDispatch (fun conn => assemble (Capabilities.held conn)) context method path body trace
      else
        managed.lanesDispatch assemble context method path body trace
  catch e =>
    trace.failure "managed" "application.failed" e
    return failed

end LeanAppNative
