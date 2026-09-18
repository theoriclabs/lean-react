import LeanApp
import LeanContract.Http
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

/-- No identity is decoded into authority. The host supplies context separately. -/
def Server.dispatch (server : Server) (context : RequestContext)
    (method path body : String) : IO HttpReply := do
  if path == server.config.manifestPath then
    if method != "GET" then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
    return ⟨200, server.config.manifest server.app.manifest⟩
  let some metadata := server.app.manifest.find? (·.http.path == path)
    | return ⟨404, Http.protocolResponse "route.not_found"⟩
  let expectedMethod := match metadata.http.method with | .post => "POST"
  if method != expectedMethod then return ⟨405, Http.protocolResponse "method.not_allowed"⟩
  if body.utf8ByteSize > server.config.maxBodyBytes then
    return ⟨413, Http.protocolResponse "request.body_too_large"⟩
  let decoded : Validation WireRequest := do
    let json ← (Lean.Json.parse body).mapError fun _ => ValidationErrors.single "decode.invalid_json"
    Http.decodeRequest server.codecs json
  let request ← match decoded with
    | .ok request => pure request
    | .error errors => return ⟨400, Http.decodeErrorResponse server.codecs errors⟩
  try
    return server.reply request.operation (← server.app.dispatchHttp context metadata.http request)
  catch _ => return ⟨500, Http.protocolResponse server.config.failureCode⟩

def respond (reply : HttpReply) : Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let status := (Std.Http.Status.ofCode none reply.status.toUInt16).getD .internalServerError
  let response ← (Std.Http.Response.withStatus status).json reply.body.compress
  pure { line := response.line, body := Std.Http.Body.Any.ofBody response.body, extensions := response.extensions }

/-- Preserve percent escapes and empty segments; never use toDecodedSegments for routing. -/
def literalPath (target : Std.Http.RequestTarget) : String := toString target.path

/-- The issuer is trusted native code, not a client principal parser. Work runs off the event loop. -/
def Server.handler (server : Server)
    (issue : Std.Http.Request Std.Http.Body.Stream → IO RequestContext)
    (request : Std.Http.Request Std.Http.Body.Stream) :
    Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let bytes : ByteArray ← try
      Std.Http.Body.Stream.readAll request.body (some server.config.maxBodyBytes.toUInt64)
    catch _ => return ← respond ⟨413, Http.protocolResponse "request.body_too_large"⟩
  let some body := String.fromUTF8? bytes
    | return ← respond ⟨400, Http.decodeErrorResponse server.codecs (ValidationErrors.single "decode.invalid_utf8")⟩
  let task ← IO.asTask (do
    try server.dispatch (← issue request) (toString request.line.method) (literalPath request.line.uri) body
    catch _ => pure ⟨500, Http.protocolResponse server.config.failureCode⟩) (prio := .dedicated)
  respond (← Std.Async.Async.ofAsyncTask task)

/-- Minimal runtime; authentication, lifecycle and deployment qualification are separate work. -/
def Server.serve (server : Server) (address : Std.Net.SocketAddress)
    (issue : Std.Http.Request Std.Http.Body.Stream → IO RequestContext) :=
  Std.Http.Server.serve address (Std.Http.Server.Handler.ofFn (server.handler issue))
    { generateDate := false, maxBodySize := server.config.maxBodyBytes, maxConnections := 64 }

end LeanAppNative
