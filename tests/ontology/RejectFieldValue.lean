import tests.ontology.Fixtures
open Ontology OntologyTests

-- This module must fail: a title lens requires the validated domain type, not raw text.
def wrongFieldValue (ticket : Ticket) := ticketTitle.set ticket "raw text"
