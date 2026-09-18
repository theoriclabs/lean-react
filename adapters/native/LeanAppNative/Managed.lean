import LeanAppNative.Server
import LeanAppNative.State
import LeanDb.Runtime

namespace LeanAppNative
open LeanApp Contract Ontology

/-- A validated server supplies frozen public metadata, codecs and HTTP policy. Its application
and handlers are not retained, so a template closure cannot keep an old database handle alive.
Each admitted call constructs fresh handlers from the session's current
connection. The trusted factory must not retain that connection or launch work using it later.
This adapter provides admission and serialization, not an implicit transaction or authentication. -/
structure Managed where
  private mk ::
  private service : LeanDb.Runtime.Service
  private approved : List PublicOperation
  private codecs : Http.Codecs
  private config : ServerConfig
  private factory : LeanDb.Conn → Validation (Application IO)
  private publicBody : Lean.Json
  readinessPath : String
  private onInvalidate : IO Unit
  private onDrainConn : LeanDb.Conn → IO Unit

def Managed.create (service : LeanDb.Runtime.Service) (template : Server)
    (factory : LeanDb.Conn → Validation (Application IO))
    (readinessPath : String := "/health/ready")
    (onInvalidate : IO Unit := pure ())
    (onDrain : LeanDb.Conn → IO Unit := fun _ => pure ()) : Validation Managed := do
  -- Host exception codes are adapter-owned; do not publish a caller's diagnostic string.
  let template ← Server.create template.app template.codecs
    { template.config with failureCode := "application.failed" }
  HttpBinding.validate { path := readinessPath }
  if readinessPath == template.config.manifestPath ||
      template.app.manifest.any (·.http.path == readinessPath) then
    Validation.fail "managed.readiness_path_collision"
  pure ⟨service, template.app.manifest, template.codecs, template.config, factory,
    template.config.manifest template.app.manifest, readinessPath, onInvalidate, onDrain⟩

/-- Factory may capture `AppState` (never `Conn`). Restore runs `AppState.invalidate`. -/
def Managed.createWithState {σ} (service : LeanDb.Runtime.Service) (template : Server)
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

/-- Do not expose Runtime.status, which contains instance paths and database diagnostics.
Readiness takes only the small runtime state lock, never the database queue. Inspection-only
sessions are also unready even though the runtime's generic ready probe does not check that flag. -/
def Managed.readiness (managed : Managed) : IO HttpReply := do
  try
    let ready := (← managed.service.ready) && !managed.service.session.readOnly
    return ⟨if ready then 200 else 503,
      .mkObj [("ok", .bool ready), ("ready", .bool ready)]⟩
  catch _ => return failed

/-- A static manifest remains available during drain/restore/closure and cannot drift with
the connection factory. All operation dispatch goes through withConnection; no argv or admin
entry point is provided. Denied admission never invokes the factory or an application handler. -/
def Managed.dispatch (managed : Managed) (context : RequestContext)
    (method path body : String) (trace : Log.TraceRef := none) : IO HttpReply := do
  if path == managed.readinessPath then
    if method != "GET" then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
    return ← managed.readiness
  if path == managed.config.manifestPath then
    if method != "GET" then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
    return ⟨200, managed.publicBody⟩
  try
    let queued ← IO.monoMsNow
    let result ← managed.service.withConnection fun conn => do
      let entered ← IO.monoMsNow
      trace.phase (fun t n => { t with queueWait := t.queueWait + n }) queued
      let assembled := fun (outcome : IO HttpReply) => do
        trace.phase (fun t n => { t with db := t.db + n }) entered
        outcome
      let .ok app := managed.factory conn | assembled (return failed)
      if app.manifest != managed.approved then return ← assembled (return failed)
      -- The factory cannot substitute HTTP/status/codec configuration. Revalidate its registry
      -- using exactly the frozen template, then use Server's existing protocol implementation.
      let .ok server := Server.create app managed.codecs managed.config
        | assembled (return failed)
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
  catch e =>
    trace.failure "managed" "application.failed" e
    return failed

end LeanAppNative
