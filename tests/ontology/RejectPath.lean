import tests.ontology.Fixtures
open Ontology OntologyTests

-- This module must fail: a String field cannot continue through a Ticket path.
def wrongComposition := titleValue.comp ticketTitle.toFieldPath
