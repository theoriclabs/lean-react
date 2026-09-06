import tests.ontology.Fixtures
open Contract OntologyTests

-- This module must fail: interpreting an operation cannot change its output type.
def wrongOutput (interpreter : Interpreter Id) (ops : Operations) : Id (CallResult String TicketError) :=
  interpreter.call ops.get 17
