import LeanAppNative.Cafe
import LeanContract.Generate

/-- Regenerates `examples/cafe/wire` from the café's approved operations:
`cd adapters/native && lake env lean --run GenerateCafeClient.lean [out]`.
`tests/cafe/wire.test.mjs` regenerates into a scratch directory and diffs the committed files. -/
def main (args : List String) : IO Unit := do
  let .ok ops := LeanAppNative.Cafe.publicOperations | throw (IO.userError "invalid cafe application")
  let .ok codecs := Contract.Http.codecs | throw (IO.userError "invalid codecs")
  let .ok statuses := LeanAppNative.Cafe.errorStatuses | throw (IO.userError "invalid save contract")
  let out : System.FilePath := (args.head?).getD "../../examples/cafe/wire"
  Contract.Generate.emitClient ops codecs statuses out (runtime := "../../../engine/LeanContract")
