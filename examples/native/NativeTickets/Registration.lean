import Examples.Tickets.Contracts
import LeanAppNative.Server

namespace NativeTickets
open LeanApp Contract Ontology Examples.Tickets Examples.Tickets.Contracts

inductive TicketRead : Type → Type where
  | list : TicketRead (Array TicketSummary)
inductive TicketWrite : Type → Type where
  | save (input : SaveTicket) : TicketWrite (Except SaveError TicketSummary)

/-- Fixture roles on the tickets, ordered viewer < editor < owner. -/
inductive Role where
  | viewer | editor | owner
  deriving Repr, BEq, DecidableEq, Ord

instance : ToString Role := ⟨fun | .viewer => "viewer" | .editor => "editor" | .owner => "owner"⟩

def localTenant := "tickets-local"

/-- Explicit local fixture membership only. Never use this table as production authentication. -/
def fixtureRoles : List (String × Role) :=
  [("local-fixture", .owner), ("fixture-editor", .editor), ("fixture-viewer", .viewer)]

def localFixtureContext : RequestContext :=
  TrustedNative.issueContext ⟨"local-fixture", localTenant, 0⟩ "local-fixture"

/-- Declared once for every binding. A caller outside the tenant or the table has no role; missing
tickets stay the handler's typed `notFound`, so responses remain uniform. -/
def roleOf [Monad m] (context : RequestContext) (_ : ReadCapability m TicketRead) (_ : Input) :
    m (Option Role) :=
  pure do
    let principal ← context.principal
    if principal.tenant != localTenant then none else fixtureRoles.lookup principal.actor

def listBinding (ops : PublicOperations) : Binding IO TicketRead TicketWrite ops.list :=
  { Policy.requireRole Role.viewer roleOf with
    http := { path := listPath }
    handler := fun _ cap _ => return .ok (← cap.read .list) }

def saveBinding (ops : PublicOperations) : Binding IO TicketRead TicketWrite ops.save :=
  { Policy.requireRole Role.editor roleOf with
    http := { path := savePath }
    handler := fun _ cap input => cap.write (.save input) }

def application (ops : PublicOperations) (service : TicketService IO) : Validation (Application IO) := do
  let read : ReadCapability IO TicketRead := { read := fun op => match op with | .list => service.list }
  let command : CommandCapability IO TicketRead TicketWrite := {
    toRead := read, write := fun op => match op with | .save input => service.save input }
  Application.create "tickets" [{ name := "tickets", exports := [
    (listBinding ops).approve (fun _ => read), (saveBinding ops).approve (fun _ => command)] }]

/-- Client metadata comes from the same typed bindings used by registration. -/
def approvedMetadata (ops : PublicOperations) : List PublicOperation :=
  [⟨ops.list.describe, (listBinding ops).http, (listBinding ops).publicMetadata⟩,
   ⟨ops.save.describe, (saveBinding ops).http, (saveBinding ops).publicMetadata⟩]

def makeServer (ops : PublicOperations) (service : TicketService IO) : Validation LeanAppNative.Server := do
  let app ← application ops service
  LeanAppNative.Server.create app ops.httpCodecs {
    errorStatuses := ops.errorStatuses, failureCode := "storage.failed" }

end NativeTickets
