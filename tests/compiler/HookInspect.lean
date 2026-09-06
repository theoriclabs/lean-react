import Examples.ReactCompiler
import Examples.Tickets.Components
import Lean.Compiler.LCNF.PrettyPrinter
open Lean Compiler LCNF
run_meta do
  for n in [`Examples.Tickets.Counter, `Examples.Tickets.useTicketEditor, `Examples.Tickets.App, `LeanReact.Hook.instMonad] do
    let d ← CompilerM.run (toDecl n)
    logInfo (← ppDecl' d .base)
