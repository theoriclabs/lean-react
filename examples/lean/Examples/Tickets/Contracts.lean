import Examples.Tickets.Domain
import LeanContract
import LeanContract.Http

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

def operationIdCodec := Contract.Http.operationIdCodec
def operationKindCodec := Contract.Http.operationKindCodec
def pathSegmentCodec := Contract.Http.pathSegmentCodec
def validationErrorsCodec := Contract.Http.validationErrorsCodec

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

def PublicOperations.httpCodecs (ops : PublicOperations) : Contract.Http.Codecs :=
  ⟨ops.codecs.operationId, ops.codecs.errors⟩

def PublicOperations.errorStatuses (ops : PublicOperations) : List Contract.Http.ErrorStatus :=
  [Contract.Http.ErrorStatus.ofOperation ops.save fun error => match error with
    | .notFound => 404 | .conflict _ => 409]

def encodeRequest (ops : PublicOperations) := Contract.Http.encodeRequest ops.httpCodecs

def decodeRequest (ops : PublicOperations) := Contract.Http.decodeRequest ops.httpCodecs

def successResponse (ops : PublicOperations) := Contract.Http.successResponse ops.httpCodecs

def domainResponse (ops : PublicOperations) (operation : OperationId) (error : SaveError) : Lean.Json :=
  Contract.Http.domainResponse ops.httpCodecs operation (ops.codecs.saveError.encode error)

def decodeErrorResponse (ops : PublicOperations) := Contract.Http.decodeErrorResponse ops.httpCodecs

def incompatibleResponse (ops : PublicOperations) := Contract.Http.incompatibleResponse ops.httpCodecs

def protocolResponse := Contract.Http.protocolResponse

def decodeHttpResponse (ops : PublicOperations) :=
  Contract.Http.decodeResponse ops.httpCodecs ops.errorStatuses

end Examples.Tickets.Contracts
