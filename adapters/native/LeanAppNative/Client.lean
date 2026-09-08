import LeanAppNative.Server
import LeanHttp

namespace LeanAppNative
open LeanApp Contract Ontology

structure Client where
  private mk ::
  origin : String
  operations : List PublicOperation
  codecs : Http.Codecs
  errorStatuses : List Http.ErrorStatus
  maxResponseBytes : Nat

def Client.create (origin : String) (operations : List PublicOperation) (codecs : Http.Codecs)
    (errorStatuses : List Http.ErrorStatus := []) (maxResponseBytes : Nat := 1024 * 1024) : Validation Client := do
  validateMetadata operations errorStatuses
  let some uri := Std.Http.URI.parse? origin | Validation.fail "http.invalid_origin"
  let some authority := uri.authority | Validation.fail "http.invalid_origin"
  if (toString uri.scheme != "http" && toString uri.scheme != "https") ||
      authority.userInfo.isSome || (toString authority.host).isEmpty ||
      (toString uri.path != "" && toString uri.path != "/") ||
      origin.contains "?" || origin.contains "#" then Validation.fail "http.invalid_origin"
  if maxResponseBytes == 0 then Validation.fail "http.invalid_body_limit"
  pure ⟨s!"{uri.scheme}://{authority}", operations, codecs, errorStatuses, maxResponseBytes⟩

/-- Select by the full approved identity. Unsupported versions fail locally, without network IO. -/
def Client.prepare (client : Client) (request : WireRequest) : Except (CallError Empty) LeanHttp.Request := do
  let metadata : PublicOperation ← match client.operations.find? (·.operation.identity == request.operation) with
    | some metadata => pure metadata
    | none =>
      match client.operations.find? (fun op =>
          op.operation.identity.namespaceName == request.operation.namespaceName &&
          op.operation.identity.name == request.operation.name) with
      | some metadata => throw (.incompatible ⟨metadata.operation.identity, request.operation⟩)
      | none => throw (.protocol ⟨"operation.not_found", none, ""⟩)
  if metadata.operation.kind != request.kind then
    throw (.protocol ⟨"operation.kind_mismatch", none, ""⟩)
  let some uri := Std.Http.URI.parse? (client.origin ++ metadata.http.path)
    | throw (.protocol ⟨"http.invalid_uri", none, ""⟩)
  return {
    method := match metadata.http.method with | .post => .post
    uri := .absolute uri, body := .json (Http.encodeRequest client.codecs request)
    redirects := .never, timeouts := { connect := .ofNat 2000, total := .ofNat 5000 } }

/-- Limit decoding of buffered responses; LeanHttp currently buffers the network body first. -/
def Client.decodeOutcome (client : Client) (request : WireRequest)
    (outcome : LeanHttp.Outcome Lean.Json) : CallResult WireResponse Empty :=
  let decode := fun (response : LeanHttp.Response) =>
    if response.body.size > client.maxResponseBytes then
      .error (.protocol ⟨"response.body_too_large", some response.statusCode.toNat, ""⟩)
    else match (LeanHttp.FromBody.fromBody response.headers response.body : Except String Lean.Json) with
      | .ok body => Http.decodeResponse client.codecs client.errorStatuses request response.statusCode.toNat body
      | .error _ => .error (.decode (ValidationErrors.single "decode.invalid_json_response"))
  match outcome with
  | .ok _ response | .status response => decode response
  | .decode _ response => decode response
  | .transport error => .error (.transport ⟨s!"curl.{error.code.toUInt32}", error.message⟩)

/-- Injectable exchange supports socket-free conformance tests of the real native outcome path. -/
def Client.transportWith (client : Client)
    (exchange : LeanHttp.Request → IO (LeanHttp.Outcome Lean.Json)) : Transport IO where
  send request := do
    match client.prepare request with
    | .error error => return .error error
    | .ok http => return client.decodeOutcome request (← exchange http)

def Client.transport (client : Client) : Transport IO :=
  client.transportWith (fun request => LeanHttp.requestAs request)

end LeanAppNative
