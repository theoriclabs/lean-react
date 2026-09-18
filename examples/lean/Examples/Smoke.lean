import Examples.ReactCompiler
import Examples.Tickets.Components
import Examples.Composition
import Examples.Foreign
import Examples.Showcase
import Examples.Feedback
import Examples.Sparkline

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/smoke.mjs" #[
    `Examples.Showcase.Counter,
    `Examples.Tickets.CounterProps.mk,
    `Examples.Tickets.Counter, `Examples.Composition.Counters, `Examples.Composition.Formatted,
    `Examples.Foreign.Interop,
    `Examples.Feedback.App,
    `Examples.Sparkline.Demo, `Examples.Sparkline.DemoProps.mk, `Examples.Sparkline.SparklineOps.mk,
    `Examples.Sparkline.SparklineOps.silent]
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
