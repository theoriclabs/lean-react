import LeanContract

namespace OntologyTests
open Ontology Contract

structure User where
  handle : String
  deriving Repr, BEq

structure Title where
  value : String
  deriving Repr, BEq, DecidableEq

def Title.ofWire (text : String) : Validation Title :=
  if text.isEmpty then Validation.fail "title.empty"
  else if text.trimAscii.toString != text then Validation.fail "title.noncanonical"
  else .ok ⟨text⟩

def Title.parse (text : String) : Validation Title := Title.ofWire text.trimAscii.toString

def titleCodec : Codec Title :=
  (Codec.string.checked Title.ofWire Title.value).named ⟨"tests", "Title"⟩

instance : HasTypeId User := ⟨⟨"tests", "User"⟩⟩

structure Ticket where
  title : Title
  priority : Nat
  owner : Option (EntityId User)
  deriving Repr, BEq

instance : HasTypeId Ticket := ⟨⟨"tests", "Ticket"⟩⟩

def ticketFields : RecordFields Ticket Ticket :=
  (RecordFields.pure Ticket.mk)
    |>.apply (RecordFields.field "title" titleCodec Ticket.title)
    |>.apply (RecordFields.field "priority" Codec.nat Ticket.priority)
    |>.apply (RecordFields.field "owner" Codec.canonical Ticket.owner)

def ticketCodec : Validation (Codec Ticket) := Codec.record ⟨"tests", "Ticket"⟩ ticketFields

def sample : Ticket := ⟨⟨"Compose foundations"⟩, 3, none⟩

structure Workspace where
  ticket : Ticket
  label : String
  deriving Repr, BEq

def workspaceTicket : Lens Workspace Ticket :=
  Lens.field ⟨"tests", "Workspace"⟩ "ticket" Workspace.ticket
    (fun workspace ticket => { workspace with ticket := ticket })

def ticketTitle : Lens Ticket Title :=
  Lens.field ⟨"tests", "Ticket"⟩ "title" Ticket.title
    (fun ticket title => { ticket with title := title })

def titleValue : FieldPath Title String :=
  FieldPath.field ⟨"tests", "Title"⟩ "value" Title.value

theorem workspaceTicket_laws : workspaceTicket.Laws := by
  constructor <;> intros <;> rfl

theorem ticketTitle_laws : ticketTitle.Laws := by
  constructor <;> intros <;> rfl

theorem composed_laws : (workspaceTicket.comp ticketTitle).Laws :=
  workspaceTicket_laws.comp ticketTitle_laws

inductive TicketField where
  | title | priority | owner
  deriving Repr, BEq, DecidableEq

def ticketDescriptor : RecordDescriptor Ticket where
  identity := ⟨"tests", "Ticket"⟩
  Field := TicketField
  Value
    | .title => Title
    | .priority => Nat
    | .owner => Option (EntityId User)
  fields := [.title, .priority, .owner]
  fieldName
    | .title => "title"
    | .priority => "priority"
    | .owner => "owner"
  valueDescriptor
    | .title => ⟨⟨"tests", "Title"⟩, "Title"⟩
    | .priority => ⟨⟨"lean", "Nat"⟩, "Priority"⟩
    | .owner => ⟨⟨"tests", "OptionalUserId"⟩, "Owner"⟩
  get
    | .title => Ticket.title
    | .priority => Ticket.priority
    | .owner => Ticket.owner
  replace?
    | .priority => some (fun ticket priority => { ticket with priority := priority })
    | _ => none

inductive Event where
  | created (id : Nat)
  | renamed (title : Title)
  | archived
  deriving Repr, BEq

inductive EventCase where
  | created | renamed | archived
  deriving Repr, BEq, DecidableEq

def eventDescriptor : VariantDescriptor Event where
  identity := ⟨"tests", "Event"⟩
  Case := EventCase
  Payload
    | .created => Nat
    | .renamed => Title
    | .archived => Unit
  cases := [.created, .renamed, .archived]
  tag
    | .created => "created"
    | .renamed => "renamed"
    | .archived => "archived"
  payloadDescriptor
    | .created => ⟨⟨"lean", "Nat"⟩, "Identifier"⟩
    | .renamed => ⟨⟨"tests", "Title"⟩, "Title"⟩
    | .archived => ⟨⟨"lean", "Unit"⟩, ""⟩
  inject
    | .created => Event.created
    | .renamed => Event.renamed
    | .archived => fun _ => Event.archived
  select
    | .created id => ⟨.created, id⟩
    | .renamed title => ⟨.renamed, title⟩
    | .archived => ⟨.archived, ()⟩

def eventPayload : (tag : eventDescriptor.Case) → Codec (eventDescriptor.Payload tag)
  | .created => Codec.nat
  | .renamed => titleCodec
  | .archived => Codec.unit

def eventCodec : Validation (Codec Event) := Codec.variant eventDescriptor eventPayload

inductive TicketError where
  | missing (id : Nat)
  | conflict (current : Ticket)
  deriving Repr, BEq

def ticketErrorCodec (ticket : Codec Ticket) : Codec TicketError :=
  (Codec.sum Codec.nat ticket).xmap
    (fun value => match value with | .inl id => .missing id | .inr current => .conflict current)
    (fun value => match value with | .missing id => .inl id | .conflict current => .inr current)

structure Operations where
  get : Operation .query Nat Ticket TicketError
  create : Operation .command Ticket Ticket TicketError

def operations : Validation Operations := do
  let ticket ← ticketCodec
  let error := ticketErrorCodec ticket
  let get ← Operation.create .query ⟨"tests.tickets", "get", "1"⟩ Codec.nat ticket error
  let create ← Operation.create .command ⟨"tests.tickets", "create", "1"⟩ ticket ticket error
  pure ⟨get, create⟩

structure TicketService (m : Type → Type) where
  get : Nat → m Ticket
  create : Ticket → m Ticket

/-- Exactly this orchestration runs with direct and wire-backed service dictionaries. -/
def duplicateTicket [Monad m] (service : TicketService m) (id : Nat) : m Ticket := do
  let original ← service.get id
  service.create { original with title := ⟨original.title.value ++ " copy"⟩, priority := original.priority + 1 }

def localService : TicketService Id where
  get _ := sample
  create ticket := { ticket with priority := ticket.priority + 10 }

def interpretedService (interpreter : Interpreter m) (ops : Operations) :
    TicketService (ExceptT (CallError TicketError) m) where
  get id := ExceptT.mk (interpreter.call ops.get id)
  create ticket := ExceptT.mk (interpreter.call ops.create ticket)

def testRouter (ops : Operations) : Validation (Router Id) := Router.create [
  Route.ofHandler ops.get (fun id =>
    if id == 0 then .error (.missing id) else .ok sample),
  Route.ofHandler ops.create (fun ticket =>
    if ticket.priority == 999 then .error (.conflict sample)
    else .ok { ticket with priority := ticket.priority + 100 })]

end OntologyTests
