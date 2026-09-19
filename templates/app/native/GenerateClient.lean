import {{Name}}Native.Application
import LeanContract.Generate

/-- `lake env lean --run GenerateClient.lean [out]` writes the browser wire client, its TypeScript
types and the embedded manifest from the approved operations (default `../web/generated`). -/
def main (args : List String) : IO Unit := do
  let .ok ops := {{Name}}Native.publicOperations | throw (IO.userError "invalid {{name}} application")
  let .ok codecs := Contract.Http.codecs | throw (IO.userError "invalid codecs")
  let .ok statuses := {{Name}}Native.errorStatuses | throw (IO.userError "invalid error statuses")
  let out : System.FilePath := (args.head?).getD "../web/generated"
  Contract.Generate.emitClient ops codecs statuses out (runtime := "@leanapp/engine/LeanContract")
