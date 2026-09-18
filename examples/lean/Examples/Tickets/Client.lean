import Examples.Tickets.Contracts
import LeanContract.Generate

namespace Examples.Tickets.Client
open Contract Examples.Tickets.Contracts

/-- Regenerates the committed browser client; `tests/integration/generated-client.test.mjs`
regenerates into a scratch directory and diffs it byte for byte. -/
def emit (out : System.FilePath := "examples/adapters/tickets-client") : IO Unit := do
  let .ok ops := publicOperations | throw (IO.userError "invalid public operations")
  Generate.emitClient ops.approved ops.httpCodecs ops.errorStatuses out
    (runtime := "../../../engine/LeanContract")

end Examples.Tickets.Client
