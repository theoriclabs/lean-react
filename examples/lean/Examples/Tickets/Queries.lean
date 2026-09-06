import Examples.Tickets.Domain
import LeanOntology.Query

namespace Examples.Tickets
open Ontology

def openTickets : Query TicketSummary TicketSummary :=
  Query.source.filter fun ticket => ticket.value.status != .done

def inboxTitles : Query TicketSummary String :=
  openTickets.map fun ticket => ticket.value.title.value

def previewTitles (count : Nat) (tickets : Array TicketSummary) : List String :=
  (inboxTitles.take count).run tickets.toList

end Examples.Tickets
