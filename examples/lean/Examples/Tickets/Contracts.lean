import Examples.Tickets.Domain
import LeanContract

namespace Examples.Tickets.Contracts
open Ontology Contract

def packageId := "leanreact.tickets"
def contractVersion := "1"
def ticketType : TypeId := ⟨packageId, "Ticket"⟩
def userType : TypeId := ⟨packageId, "User"⟩
def listIdentity : OperationId := ⟨packageId, "list", contractVersion⟩
def saveIdentity : OperationId := ⟨packageId, "save", contractVersion⟩

def titleCodec : Codec Title :=
  (Codec.string.checked (fun value =>
    (Title.parse value).mapError fun error => match error with
      | .empty => ValidationErrors.single "title.empty"
      | .tooLong length => ValidationErrors.single "title.too_long" [] [("length", toString length)])
    Title.value).named ⟨packageId, "Title"⟩

def statusName : Status → String
  | .backlog => "backlog"
  | .inProgress => "inProgress"
  | .done => "done"

def statusCodec : Codec Status :=
  (Codec.string.checked (fun value => match value with
    | "backlog" => .ok .backlog
    | "inProgress" => .ok .inProgress
    | "done" => .ok .done
    | _ => Validation.fail "status.unknown" [] [("actual", value)]) statusName)
    |>.named ⟨packageId, "Status"⟩

def ticketIdCodec : Codec TicketId := Codec.entityId ticketType
def userIdCodec : Codec (EntityId User) := Codec.entityId userType

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

structure PublicCodecs where
  ticket : Codec Ticket
  summary : Codec TicketSummary
  saveInput : Codec SaveTicket
  saveError : Codec SaveError
  operationId : Codec OperationId
  errors : Codec ValidationErrors

def publicCodecs : Validation PublicCodecs := do
  let ticket ← Codec.record ⟨packageId, "TicketValue"⟩ <|
    (RecordFields.pure Ticket.mk)
      |>.apply (RecordFields.field "title" titleCodec Ticket.title)
      |>.apply (RecordFields.field "status" statusCodec Ticket.status)
      |>.apply (RecordFields.field "assignee" (Codec.option userIdCodec) Ticket.assignee)
  let summary ← Codec.record ⟨packageId, "TicketSummary"⟩ <|
    (RecordFields.pure TicketSummary.mk)
      |>.apply (RecordFields.field "id" ticketIdCodec TicketSummary.id)
      |>.apply (RecordFields.field "revision" Codec.nat TicketSummary.revision)
      |>.apply (RecordFields.field "value" ticket TicketSummary.value)
  let saveInput ← Codec.record ⟨packageId, "SaveTicket"⟩ <|
    (RecordFields.pure SaveTicket.mk)
      |>.apply (RecordFields.field "id" ticketIdCodec SaveTicket.id)
      |>.apply (RecordFields.field "expectedRevision" Codec.nat SaveTicket.expectedRevision)
      |>.apply (RecordFields.field "title" titleCodec SaveTicket.title)
      |>.apply (RecordFields.field "status" statusCodec SaveTicket.status)
  let saveError : Codec SaveError := {
    schema := .named ⟨packageId, "SaveError"⟩ "1"
      (.variant [("notFound", .unit), ("conflict", summary.schema)])
    encode := fun error => match error with
      | .notFound => JsonWire.tagged "notFound" .null
      | .conflict current => JsonWire.tagged "conflict" (summary.encode current)
    decode := fun value => do
      JsonWire.object ["tag", "value"] value
      let tag ← JsonWire.stringField "tag" value
      match tag with
      | "notFound" => do let _ ← Codec.field "value" Codec.unit value; pure .notFound
      | "conflict" => SaveError.conflict <$> Codec.field "value" summary value
      | _ => Validation.fail "decode.unknown_save_error" [.key "tag"] }
  pure ⟨ticket, summary, saveInput, saveError, ← operationIdCodec, ← validationErrorsCodec⟩

structure PublicOperations where
  codecs : PublicCodecs
  list : Operation .query Unit (Array TicketSummary) Unit
  save : Operation .command SaveTicket TicketSummary SaveError

def publicOperations : Validation PublicOperations := do
  let codecs ← publicCodecs
  let list ← Operation.create .query listIdentity Codec.unit (Codec.array codecs.summary) Codec.unit
  let save ← Operation.create .command saveIdentity codecs.saveInput codecs.summary codecs.saveError
  pure ⟨codecs, list, save⟩

def PublicOperations.manifest (ops : PublicOperations) : Lean.Json :=
  .mkObj [("protocol", .str "tickets-http/1"),
    ("operations", .arr #[ops.list.describe.toJson, ops.save.describe.toJson]),
    ("routes", .mkObj [("list", .str "/api/tickets/list"), ("save", .str "/api/tickets/save")])]

def encodeRequest (ops : PublicOperations) (request : WireRequest) : Lean.Json :=
  .mkObj [("operation", ops.codecs.operationId.encode request.operation),
    ("kind", operationKindCodec.encode request.kind), ("input", request.input)]

def decodeRequest (ops : PublicOperations) (value : Lean.Json) : Validation WireRequest := do
  JsonWire.object ["operation", "kind", "input"] value
  let operation ← Codec.field "operation" ops.codecs.operationId value
  Validation.prependPath [.key "operation"] operation.validate
  let kind ← Codec.field "kind" operationKindCodec value
  let input ← JsonWire.get "input" value
  pure ⟨operation, kind, input⟩

def successResponse (ops : PublicOperations) (operation : OperationId) (value : Lean.Json) : Lean.Json :=
  .mkObj [("operation", ops.codecs.operationId.encode operation), ("tag", .str "success"), ("value", value)]

def domainResponse (ops : PublicOperations) (operation : OperationId) (error : SaveError) : Lean.Json :=
  .mkObj [("operation", ops.codecs.operationId.encode operation), ("tag", .str "domainError"),
    ("value", ops.codecs.saveError.encode error)]

def decodeErrorResponse (ops : PublicOperations) (errors : ValidationErrors) : Lean.Json :=
  .mkObj [("tag", .str "decode"), ("errors", ops.codecs.errors.encode errors)]

def incompatibleResponse (ops : PublicOperations) (expected received : OperationId) : Lean.Json :=
  .mkObj [("tag", .str "incompatible"), ("expected", ops.codecs.operationId.encode expected),
    ("received", ops.codecs.operationId.encode received)]

def protocolResponse (code : String) : Lean.Json :=
  .mkObj [("tag", .str "protocol"), ("code", .str code)]

/-- Shared status policy: a non-2xx body is deliberately decoded, never discarded. -/
def decodeHttpResponse (ops : PublicOperations) (request : WireRequest)
    (status : Nat) (body : Lean.Json) : Except (CallError Empty) WireResponse := do
  let tag ← (JsonWire.stringField "tag" body).mapError CallError.decode
  let protocol := fun code => CallError.protocol ⟨code, some status, ""⟩
  match tag with
  | "success" | "domainError" =>
    let _ ← (JsonWire.object ["operation", "tag", "value"] body).mapError CallError.decode
    let identity ← (Codec.field "operation" ops.codecs.operationId body).mapError CallError.decode
    if identity != request.operation then throw (protocol "response.operation_mismatch")
    let value ← (JsonWire.get "value" body).mapError CallError.decode
    if tag == "success" then
      if status == 200 then pure (.success value) else throw (protocol "response.status_mismatch")
    else
      if request.operation != ops.save.identity then throw (protocol "response.unexpected_domain_error")
      let error ← (ops.codecs.saveError.decode value).mapError CallError.decode
      let expectedStatus := match error with | .notFound => 404 | .conflict _ => 409
      if status != expectedStatus then throw (protocol "response.status_mismatch")
      pure (.domainError value)
  | "decode" =>
    if status != 400 then throw (protocol "response.status_mismatch")
    let errors ← (Codec.field "errors" ops.codecs.errors body).mapError CallError.decode
    throw (.decode errors)
  | "incompatible" =>
    if status != 409 then throw (protocol "response.status_mismatch")
    let expected ← (Codec.field "expected" ops.codecs.operationId body).mapError CallError.decode
    let received ← (Codec.field "received" ops.codecs.operationId body).mapError CallError.decode
    if received != request.operation then throw (protocol "response.operation_mismatch")
    throw (.incompatible ⟨expected, received⟩)
  | "protocol" =>
    if status < 400 then throw (protocol "response.status_mismatch")
    let code ← (JsonWire.stringField "code" body).mapError CallError.decode
    throw (protocol code)
  | _ => throw (protocol "response.unknown_tag")

end Examples.Tickets.Contracts
