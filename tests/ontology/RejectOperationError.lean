import tests.ontology.Fixtures
open Contract OntologyTests

-- This module must fail: interpreting an operation cannot erase its domain error type.
def wrongError (interpreter : Interpreter Id) (ops : Operations) : Id (CallResult Ticket String) :=
  interpreter.call ops.get 17
