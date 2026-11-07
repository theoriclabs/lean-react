import Examples.ReactCompiler
import Examples.Tickets.Components
import Examples.Composition
import Examples.Foreign
import Examples.Showcase
import Examples.Feedback
import Examples.Sparkline
import Examples.Routing
import Examples.Diagram
import Examples.Large
import Examples.Styles
import Examples.Program

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanReact.Compiler.writeStylesheet "examples/generated/styles.css" #[`Examples.Styles]
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/smoke.mjs" #[
    `Examples.Showcase.Counter,
    `Examples.Tickets.CounterProps.mk,
    `Examples.Tickets.Counter, `Examples.Composition.Counters, `Examples.Composition.Formatted,
    `Examples.Foreign.Interop,
    `Examples.Feedback.App,
    `Examples.Sparkline.Demo, `Examples.Sparkline.DemoProps.mk, `Examples.Sparkline.SparklineOps.mk,
    `Examples.Sparkline.SparklineOps.silent,
    `Examples.Diagram.Demo, `Examples.Diagram.ArchitectureDiagram, `Examples.Diagram.Timeline,
    `Examples.Large.Demo, `Examples.Large.EventList, `Examples.Large.EventGrid, `Examples.Large.TimelineDemo,
    `Examples.Styles.Demo,
    `Examples.Program.Counter, `Examples.Program.Todos, `Examples.Program.CounterMsg.add,
    `Examples.Program.counterElement, `Examples.Program.todosElement, `Examples.Program.logged,
    `Examples.Program.boardElement, `Examples.Program.Interop, `Examples.Program.nestedElement, `Examples.Program.clockElement, `Examples.Program.watcherElement,
    `Examples.Routing.App, `Examples.Routing.codec, `LeanReact.Query.parse, `LeanReact.Query.encode]
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
