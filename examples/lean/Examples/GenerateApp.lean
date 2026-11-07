import Examples.ReactCompiler
import Examples.Tickets.Components
import Examples.Collections
import Examples.Feedback

/- Three pages of one application compiled together (`LeanJS.writeApp`): what two or more pages
reach is compiled once into `shared.mjs`, and each page imports it. -/
run_meta do
  let shared ← LeanJS.writeApp "examples/generated/app" #[
    ("tickets", #[`Examples.Tickets.App]),
    ("collections", #[`Examples.Collections.App]),
    ("feedback", #[`Examples.Feedback.App])]
    (LeanReact.Compiler.options "../../../engine/adapters/leanjs-react.mjs")
    (sharedId := ⟨"leanreact-examples", "0.3.0", "shared"⟩)
  IO.println s!"writeApp: {shared.size} declarations shared by two or more pages"
