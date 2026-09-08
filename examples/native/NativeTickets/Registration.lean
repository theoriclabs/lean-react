import Examples.Tickets.Contracts
import LeanAppNative.Server

namespace NativeTickets
open LeanApp Contract Ontology Examples.Tickets Examples.Tickets.Contracts

inductive TicketRead : Type → Type where
  | list : TicketRead (Array TicketSummary)
inductive TicketWrite : Type → Type where
  | save (input : SaveTicket) : TicketWrite (Except SaveError TicketSummary)

/-- Explicit local fixture authority only. Never use this issuer as production authentication. -/
def localFixtureContext : RequestContext :=
  TrustedNative.issueContext ⟨"local-fixture", "tickets-local", 0⟩ "local-fixture"

def localFixturePolicy [Monad m] (op : Operation k Input Output Error) : Policy m TicketRead op :=
  fun context _ _ => pure <| match context.principal with
    | none => .error .unauthenticated
    | some principal => if principal.tenant == "tickets-local" then .ok () else .error .forbidden

def listBinding (ops : PublicOperations) : Binding IO TicketRead TicketWrite ops.list where
  http := { path := "/api/tickets/list" }
  policy := localFixturePolicy ops.list
  handler _ cap _ := return .ok (← cap.read .list)

def saveBinding (ops : PublicOperations) : Binding IO TicketRead TicketWrite ops.save where
  http := { path := "/api/tickets/save" }
  policy := localFixturePolicy ops.save
  handler _ cap input := cap.write (.save input)

def application (ops : PublicOperations) (service : TicketService IO) : Validation (Application IO) := do
  let read : ReadCapability IO TicketRead := { read := fun op => match op with | .list => service.list }
  let command : CommandCapability IO TicketRead TicketWrite := {
    toRead := read, write := fun op => match op with | .save input => service.save input }
  Application.create "tickets" [{ name := "tickets", exports := [
    (listBinding ops).approve (fun _ => read), (saveBinding ops).approve (fun _ => command)] }]

/-- Client metadata comes from the same typed bindings used by registration. -/
def approvedMetadata (ops : PublicOperations) : List PublicOperation :=
  [⟨ops.list.describe, (listBinding ops).http, (listBinding ops).metadata⟩,
   ⟨ops.save.describe, (saveBinding ops).http, (saveBinding ops).metadata⟩]

def makeServer (ops : PublicOperations) (service : TicketService IO) : Validation LeanAppNative.Server := do
  let app ← application ops service
  LeanAppNative.Server.create app ops.httpCodecs {
    errorStatuses := ops.errorStatuses
    manifest := fun approved => .mkObj [
      ("protocol", .str "tickets-http/1"),
      ("operations", .arr (approved.map (·.operation.toJson)).toArray),
      ("routes", .mkObj (approved.map fun op => (op.operation.identity.name, .str op.http.path)))]
    failureCode := "storage.failed" }

end NativeTickets
