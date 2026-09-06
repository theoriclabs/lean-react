import Examples.ReactCompiler
import Examples.Tickets.Components
import Examples.Composition
import Examples.Foreign

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/smoke.mjs" #[
    `Examples.Composition.formatterContext,
    `Examples.Tickets.CounterProps.mk,
    `Examples.Tickets.Counter, `Examples.Composition.Counters, `Examples.Composition.Formatted,
    `Examples.Foreign.Interop]
    { Examples.reactOptions with intrinsics := Examples.reactIntrinsics ++ #[{
        leanName := `Examples.Composition.instTypeNameFormatter
        module := Examples.reactModule
        exportName := "erased"
        arity := 0
      }, {
        leanName := `Examples.Foreign.thirdPartyButton
        module := "../adapters/example-foreign.mjs"
        exportName := "thirdPartyButton"
        arity := 1
      }] }
