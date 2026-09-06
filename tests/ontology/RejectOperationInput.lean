import tests.ontology.Fixtures
open Contract OntologyTests

-- This module must fail: a transport interpreter preserves the operation's input type.
def wrongInput (interpreter : Interpreter Id) (ops : Operations) :=
  interpreter.call ops.get "17"
