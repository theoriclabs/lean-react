import tests.ontology.Fixtures
open Ontology OntologyTests

-- This module must fail: equal key representations do not identify equal entity types.
def wrongReference (ticket : EntityId Ticket) : EntityId User := ticket
