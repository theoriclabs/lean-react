import tests.ontology.Fixtures
open Contract OntologyTests

-- This module must fail: query/command is a type index, not just metadata.
def wrongKind (ops : Operations) : Operation .command Nat Ticket TicketError := ops.get
