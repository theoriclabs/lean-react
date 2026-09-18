import LeanApp
import LeanContract.Http
import LeanAppNative.Metrics
import Std.Http

namespace LeanAppNative
open LeanApp Contract Ontology

structure HttpReply where
  status : Nat
  body : Lean.Json

def HttpReply.toJson (reply : HttpReply) : Lean.Json :=
  .mkObj [("status", Lean.toJson reply.status), ("body", reply.body)]

/-- Each entry carries `http` and `metadata`; the portable emitter keeps generated clients identical. -/
def publicManifest (operations : List PublicOperation) : Lean.Json :=
  PublicOperation.manifest operations

structure ServerConfig where
  manifestPath : String := "/api/manifest"
  manifest : List PublicOperation → Lean.Json := publicManifest
  errorStatuses : List Http.ErrorStatus := []
  maxBodyBytes : Nat := 1024 * 1024
  failureCode : String := "handler.failed"
  /-- Simultaneous connections accepted by the listener; 0 removes the cap (see `Std.Http.Config`). -/
  maxConnections : Nat := 64

/-- The body cap for a literal path: the binding's own `maxBodyBytes` or the server default. -/
def bodyLimitFor (operations : List PublicOperation) (config : ServerConfig) (path : String) : Nat :=
  ((operations.find? (·.http.path == path)).bind (·.http.maxBodyBytes)).getD config.maxBodyBytes

/-- The protocol-level body cap: the largest limit any path may accept. -/
def wireBodyLimitFor (operations : List PublicOperation) (config : ServerConfig) : Nat :=
  operations.foldl (fun acc op => max acc (op.http.maxBodyBytes.getD 0)) config.maxBodyBytes

/-- Also used by clients accepting approved public metadata without native handlers. -/
def validateMetadata (operations : List PublicOperation) (statuses : List Http.ErrorStatus) : Validation Unit := do
  let mut identities : List OperationId := []
  let mut paths : List String := []
  for op in operations do
    op.operation.identity.validate
    op.http.validate
    if identities.contains op.operation.identity then Validation.fail "operation.duplicate_identity"
    if paths.contains op.http.path then Validation.fail "http.ambiguous_path"
    identities := op.operation.identity :: identities
    paths := op.http.path :: paths
  let mut policies : List OperationId := []
  for policy in statuses do
    if !identities.contains policy.identity then Validation.fail "http.status_not_exported"
    if policies.contains policy.identity then Validation.fail "http.duplicate_status_policy"
    policies := policy.identity :: policies

structure Server where
  private mk ::
  app : Application IO
  codecs : Http.Codecs
  config : ServerConfig

def Server.create (app : Application IO) (codecs : Http.Codecs)
    (config : ServerConfig := {}) : Validation Server := do
  validateMetadata app.manifest config.errorStatuses
  HttpBinding.validate { path := config.manifestPath }
  if app.manifest.any (·.http.path == config.manifestPath) then
    Validation.fail "http.manifest_path_collision"
  if config.maxBodyBytes == 0 || config.maxBodyBytes > 2^32 then
    Validation.fail "http.invalid_body_limit"
  pure ⟨app, codecs, config⟩

def Server.reply (server : Server) (identity : OperationId)
    (result : CallResult WireResponse Empty) : HttpReply :=
  match result with
  | .ok (.success value) => ⟨200, Http.successResponse server.codecs identity value⟩
  | .ok (.domainError value) =>
    match Http.domainStatus server.config.errorStatuses identity value with
    | .ok status => ⟨status, Http.domainResponse server.codecs identity value⟩
    | .error _ => ⟨500, Http.protocolResponse "response.invalid_domain_status"⟩
  | .error (.unauthenticated) => ⟨401, .mkObj [("tag", .str "unauthenticated")]⟩
  | .error (.forbidden) => ⟨403, .mkObj [("tag", .str "forbidden")]⟩
  | .error (.decode errors) => ⟨400, Http.decodeErrorResponse server.codecs errors⟩
  | .error (.incompatible mismatch) =>
    ⟨409, Http.incompatibleResponse server.codecs mismatch.expected mismatch.received⟩
  | .error (.protocol error) => ⟨400, Http.protocolResponse error.code⟩
  | .error (.domain impossible) => nomatch impossible
  | .error _ => ⟨500, Http.protocolResponse server.config.failureCode⟩

/-- No identity is decoded into authority. The host supplies context separately. The optional
trace receives the operation, outcome, handler time and any caught exception for the request log. -/
def Server.dispatch (server : Server) (context : RequestContext)
    (method path body : String) (trace : Log.TraceRef := none) : IO HttpReply := do
  if path == server.config.manifestPath then
    if method != "GET" then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
    return ⟨200, server.config.manifest server.app.manifest⟩
  let some metadata := server.app.manifest.find? (·.http.path == path)
    | return ⟨404, Http.protocolResponse "route.not_found"⟩
  trace.update fun t => { t with operation := some metadata.operation.identity }
  trace.principal context
  let expectedMethod := match metadata.http.method with | .post => "POST"
  if method != expectedMethod then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
  if body.utf8ByteSize > metadata.http.maxBodyBytes.getD server.config.maxBodyBytes then
    return ⟨413, Http.protocolResponse "request.body_too_large"⟩
  let decoded : Validation WireRequest := do
    let json ← (Lean.Json.parse body).mapError fun _ => ValidationErrors.single "decode.invalid_json"
    Http.decodeRequest server.codecs json
  let request ← match decoded with
    | .ok request => pure request
    | .error errors =>
      trace.update fun t => { t with outcome := some .decode }
      return ⟨400, Http.decodeErrorResponse server.codecs errors⟩
  let started ← IO.monoMsNow
  try
    let result ← server.app.dispatchHttp context metadata.http request
    trace.phase (fun t n => { t with handler := t.handler + n }) started
    trace.update fun t => { t with outcome := some (Log.Outcome.ofResult result) }
    return server.reply request.operation result
  catch e =>
    trace.phase (fun t n => { t with handler := t.handler + n }) started
    trace.failure "server" server.config.failureCode e
    return ⟨500, Http.protocolResponse server.config.failureCode⟩

def respond (reply : HttpReply) : Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let status := (Std.Http.Status.ofCode none reply.status.toUInt16).getD .internalServerError
  let response ← (Std.Http.Response.withStatus status).json reply.body.compress
  pure { line := response.line, body := Std.Http.Body.Any.ofBody response.body, extensions := response.extensions }

/-- Preserve percent escapes and empty segments; never use toDecodedSegments for routing. -/
def literalPath (target : Std.Http.RequestTarget) : String := toString target.path

/-- A single request header by lowercase name; ambiguous headers count as absent. -/
def requestHeader (request : Std.Http.Request Std.Http.Body.Stream) (name : String) : Option String :=
  match request.line.headers.toList.filter (fun (key, _) => (toString key).toLower == name) with
  | [(_, value)] => some (toString value)
  | _ => none

/-- Emit the request line and count it. `replyBytes` is the serialized JSON size. -/
def logRequest (trace : IO.Ref Log.Trace) (method path : String) (status : Nat) (started bodyBytes replyBytes : Nat) :
    IO Unit := do
  Metrics.observe (← Log.request (← trace.get) method path status started bodyBytes replyBytes)

/-- The issuer is trusted native code, not a client principal parser. Work runs off the event loop.
The per-path body cap is chosen by literal path before any byte is buffered; the request id
(`X-Request-Id` when well-formed) reaches `RequestContext.requestId` and the log line. -/
def Server.handler (server : Server)
    (issue : Std.Http.Request Std.Http.Body.Stream → IO RequestContext)
    (request : Std.Http.Request Std.Http.Body.Stream) :
    Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let started ← IO.monoMsNow
  let path := literalPath request.line.uri
  let method := toString request.line.method
  let trace ← IO.mkRef ({ requestId := ← Log.requestId (requestHeader request "x-request-id") } : Log.Trace)
  let finish := fun (reply : HttpReply) (bodyBytes : Nat) => do
    logRequest trace method path reply.status started bodyBytes reply.body.compress.utf8ByteSize
    respond reply
  let bytes : ByteArray ← try
      Std.Http.Body.Stream.readAll request.body (some (bodyLimitFor server.app.manifest server.config path).toUInt64)
    catch _ => return ← finish ⟨413, Http.protocolResponse "request.body_too_large"⟩ 0
  let some body := String.fromUTF8? bytes
    | return ← finish ⟨400, Http.decodeErrorResponse server.codecs (ValidationErrors.single "decode.invalid_utf8")⟩ bytes.size
  let task ← IO.asTask (do
    try
      let context := Log.withRequestId (← issue request) (← trace.get).requestId
      server.dispatch context method path body (some trace)
    catch e =>
      Log.TraceRef.failure (some trace) "server" server.config.failureCode e
      pure ⟨500, Http.protocolResponse server.config.failureCode⟩) (prio := .dedicated)
  finish (← Std.Async.Async.ofAsyncTask task) bytes.size

/-- Minimal runtime; authentication, lifecycle and deployment qualification are separate work. -/
def Server.serve (server : Server) (address : Std.Net.SocketAddress)
    (issue : Std.Http.Request Std.Http.Body.Stream → IO RequestContext) :=
  Std.Http.Server.serve address (Std.Http.Server.Handler.ofFn (server.handler issue))
    { generateDate := false, maxBodySize := wireBodyLimitFor server.app.manifest server.config
      maxConnections := server.config.maxConnections }

end LeanAppNative
