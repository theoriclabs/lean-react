import LeanOntology.Identity

namespace Examples.Tickets

open Ontology

structure Title where
  value : String
  deriving Repr, BEq, DecidableEq

inductive TitleError where
  | empty
  | tooLong (length : Nat)
  deriving Repr, BEq, DecidableEq

def Title.parse (raw : String) : Except TitleError Title :=
  if raw.isEmpty then .error .empty
  else if raw.length > 200 then .error (.tooLong raw.length)
  else .ok ⟨raw⟩

def TitleError.message : TitleError → String
  | .empty => "Give the ticket a title."
  | .tooLong length => "Keep the title under 201 characters (currently " ++ toString length ++ ")."

inductive Status where
  | backlog | inProgress | done
  deriving Repr, BEq, DecidableEq

def Status.label : Status → String
  | .backlog => "Backlog"
  | .inProgress => "In progress"
  | .done => "Done"

def Status.parse : String → Option Status
  | "backlog" => some .backlog
  | "inProgress" => some .inProgress
  | "done" => some .done
  | _ => none

def Status.next : Status → Status
  | .backlog => .inProgress
  | .inProgress => .done
  | .done => .backlog

structure User where
  name : String
  deriving Repr, BEq, DecidableEq

structure Ticket where
  title : Title
  status : Status := .backlog
  assignee : Option (EntityId User) := none
  deriving Repr, BEq, DecidableEq

abbrev TicketId := EntityId Ticket

structure TicketSummary where
  id : TicketId
  revision : Nat
  value : Ticket
  deriving Repr, BEq, DecidableEq

structure SaveTicket where
  id : TicketId
  expectedRevision : Nat
  title : Title
  status : Status
  deriving Repr, BEq, DecidableEq

inductive SaveError where
  | notFound
  | conflict (current : TicketSummary)
  deriving Repr, BEq, DecidableEq

/-- The service is a value: applications can use native, remote, or local implementations. -/
structure TicketService (m : Type → Type) where
  list : m (Array TicketSummary)
  save : SaveTicket → m (Except SaveError TicketSummary)

/-- Used unchanged by browser previews and server-side command handlers. -/
def applySave (current : TicketSummary) (input : SaveTicket) : Except SaveError TicketSummary :=
  if current.id != input.id then .error .notFound
  else if current.revision != input.expectedRevision then .error (.conflict current)
  else .ok { current with
    revision := current.revision + 1
    value := { current.value with title := input.title, status := input.status }
  }

def countOpen (tickets : Array TicketSummary) : Nat :=
  tickets.foldl (fun total ticket => if ticket.value.status == .done then total else total + 1) 0

def onlyOpen (tickets : Array TicketSummary) : Array TicketSummary :=
  tickets.filter (fun ticket => ticket.value.status != .done)

/-- Ordinary higher-order reuse works outside the UI as well. -/
def renderTitles (render : Title → String) (tickets : Array TicketSummary) : Array String :=
  tickets.map fun ticket => render ticket.value.title

private def sample (key title : String) (status : Status) : Validation TicketSummary := do
  let id ← EntityId.parse "tickets-demo" key
  pure { id, revision := 1, value := { title := ⟨title⟩, status } }

def seed : Validation (Array TicketSummary) := do
  pure #[
    ← sample "1" "Make components ordinary values" .inProgress,
    ← sample "2" "Share a hook across two layouts" .backlog,
    ← sample "3" "Swap the service, keep the interface" .done
  ]

end Examples.Tickets
