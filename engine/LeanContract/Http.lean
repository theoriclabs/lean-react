import LeanContract.Transport

/-! Shared HTTP envelope codecs. Domain codecs and status choices stay explicit. -/
namespace Contract.Http
open Ontology

def operationIdCodec : Validation (Codec OperationId) :=
  Codec.record ⟨"leancontract", "OperationId"⟩ <|
    (RecordFields.pure OperationId.mk)
      |>.apply (RecordFields.field "namespace" Codec.string OperationId.namespaceName)
      |>.apply (RecordFields.field "name" Codec.string OperationId.name)
      |>.apply (RecordFields.field "version" Codec.string OperationId.version)

def operationKindCodec : Codec OperationKind :=
  Codec.string.checked (fun value => match value with
    | "query" => .ok .query
    | "command" => .ok .command
    | _ => Validation.fail "operation.unknown_kind")
    (fun kind => match kind with | .query => "query" | .command => "command")

/-- Error paths use explicit segment tags, including exact integer indices. -/
def pathSegmentCodec : Codec PathSegment where
  schema := .named ⟨"ontology", "PathSegment"⟩ "1" (.variant
    [("key", .string), ("index", .natural), ("variant", .string),
     ("field", .record [("package", .string), ("owner", .string), ("name", .string)])])
  encode
    | .key name => JsonWire.tagged "key" (.str name)
    | .index value => JsonWire.tagged "index" (Codec.nat.encode value)
    | .variant tag => JsonWire.tagged "variant" (.str tag)
    | .field owner name => JsonWire.tagged "field" (.mkObj
        [("package", .str owner.packageName), ("owner", .str owner.name), ("name", .str name)])
  decode value := do
    JsonWire.object ["tag", "value"] value
    let tag ← JsonWire.stringField "tag" value
    match tag with
    | "key" => PathSegment.key <$> Codec.field "value" Codec.string value
    | "index" => PathSegment.index <$> Codec.field "value" Codec.nat value
    | "variant" => PathSegment.variant <$> Codec.field "value" Codec.string value
    | "field" => do
      let payload ← JsonWire.get "value" value
      JsonWire.object ["package", "owner", "name"] payload
      let packageName ← JsonWire.stringField "package" payload
      let owner ← JsonWire.stringField "owner" payload
      let name ← JsonWire.stringField "name" payload
      pure (.field ⟨packageName, owner⟩ name)
    | _ => Validation.fail "decode.unknown_path_segment"

def validationErrorsCodec : Validation (Codec ValidationErrors) := do
  let error ← Codec.record ⟨"ontology", "ValidationError"⟩ <|
    (RecordFields.pure ValidationError.mk)
      |>.apply (RecordFields.field "code" Codec.string ValidationError.code)
      |>.apply (RecordFields.field "path" (Codec.list pathSegmentCodec) ValidationError.path)
      |>.apply (RecordFields.field "params" (Codec.list (Codec.product Codec.string Codec.string)) ValidationError.params)
  pure <| (Codec.list error).checked (fun errors => match errors with
    | [] => Validation.fail "decode.empty_errors"
    | first :: rest => .ok ⟨first, rest⟩) ValidationErrors.toList

structure Codecs where
  operationId : Codec OperationId
  errors : Codec ValidationErrors

def codecs : Validation Codecs := do
  return ⟨← operationIdCodec, ← validationErrorsCodec⟩

/-- A domain status function is paired with its typed operation before erasure. -/
structure ErrorStatus where
  identity : OperationId
  decodeStatus : Lean.Json → Validation Nat

def ErrorStatus.ofOperation (operation : Operation kind Input Output Error)
    (status : Error → Nat) : ErrorStatus :=
  ⟨operation.identity, fun value => status <$> operation.errorCodec.decode value⟩

def domainStatus (policies : List ErrorStatus) (identity : OperationId)
    (value : Lean.Json) : Validation Nat := do
  let some policy := policies.find? (·.identity == identity)
    | Validation.fail "response.unexpected_domain_error"
  let status ← policy.decodeStatus value
  if status < 400 || status > 599 then Validation.fail "response.invalid_domain_status"
  pure status

def encodeRequest (codecs : Codecs) (request : WireRequest) : Lean.Json :=
  .mkObj [("operation", codecs.operationId.encode request.operation),
    ("kind", operationKindCodec.encode request.kind), ("input", request.input)]

def decodeRequest (codecs : Codecs) (value : Lean.Json) : Validation WireRequest := do
  JsonWire.object ["operation", "kind", "input"] value
  let operation ← Codec.field "operation" codecs.operationId value
  Validation.prependPath [.key "operation"] operation.validate
  let kind ← Codec.field "kind" operationKindCodec value
  return ⟨operation, kind, ← JsonWire.get "input" value⟩

def successResponse (codecs : Codecs) (operation : OperationId) (value : Lean.Json) : Lean.Json :=
  .mkObj [("operation", codecs.operationId.encode operation), ("tag", .str "success"), ("value", value)]

def domainResponse (codecs : Codecs) (operation : OperationId) (error : Lean.Json) : Lean.Json :=
  .mkObj [("operation", codecs.operationId.encode operation), ("tag", .str "domainError"), ("value", error)]

def decodeErrorResponse (codecs : Codecs) (errors : ValidationErrors) : Lean.Json :=
  .mkObj [("tag", .str "decode"), ("errors", codecs.errors.encode errors)]

def incompatibleResponse (codecs : Codecs) (expected received : OperationId) : Lean.Json :=
  .mkObj [("tag", .str "incompatible"), ("expected", codecs.operationId.encode expected),
    ("received", codecs.operationId.encode received)]

def protocolResponse (code : String) : Lean.Json :=
  .mkObj [("tag", .str "protocol"), ("code", .str code)]

/-- Decode bodies on non-2xx responses too. Identity and status are checked
before an application sees a declared result; no operation names are hard-coded. -/
def decodeResponse (codecs : Codecs) (policies : List ErrorStatus) (request : WireRequest)
    (status : Nat) (body : Lean.Json) : Except (CallError Empty) WireResponse := do
  let tag ← (JsonWire.stringField "tag" body).mapError CallError.decode
  let protocol := fun code => CallError.protocol ⟨code, some status, ""⟩
  match tag with
  | "success" | "domainError" =>
    let _ ← (JsonWire.object ["operation", "tag", "value"] body).mapError CallError.decode
    let identity ← (Codec.field "operation" codecs.operationId body).mapError CallError.decode
    if identity != request.operation then throw (protocol "response.operation_mismatch")
    let value ← (JsonWire.get "value" body).mapError CallError.decode
    if tag == "success" then
      if status == 200 then pure (.success value) else throw (protocol "response.status_mismatch")
    else
      if !(policies.any (·.identity == identity)) then
        throw (protocol "response.unexpected_domain_error")
      let expectedStatus ← (domainStatus policies identity value).mapError CallError.decode
      if status != expectedStatus then throw (protocol "response.status_mismatch")
      pure (.domainError value)
  | "decode" =>
    if status != 400 then throw (protocol "response.status_mismatch")
    let errors ← (Codec.field "errors" codecs.errors body).mapError CallError.decode
    throw (.decode errors)
  | "incompatible" =>
    if status != 409 then throw (protocol "response.status_mismatch")
    let expected ← (Codec.field "expected" codecs.operationId body).mapError CallError.decode
    let received ← (Codec.field "received" codecs.operationId body).mapError CallError.decode
    if received != request.operation then throw (protocol "response.operation_mismatch")
    throw (.incompatible ⟨expected, received⟩)
  | "unauthenticated" =>
    if status != 401 then throw (protocol "response.status_mismatch")
    throw .unauthenticated
  | "forbidden" =>
    if status != 403 then throw (protocol "response.status_mismatch")
    throw .forbidden
  | "protocol" =>
    if status < 400 then throw (protocol "response.status_mismatch")
    let code ← (JsonWire.stringField "code" body).mapError CallError.decode
    throw (protocol code)
  | _ => throw (protocol "response.unknown_tag")

end Contract.Http
