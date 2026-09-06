-- Optional developer inspection after `npm run test:compiler` has built the corpus.
import tests.compiler.Corpus
import Lean.Compiler.LCNF.PrettyPrinter
open Lean Compiler LCNF
run_meta do
  for n in [`Corpus.useCapture, `Corpus.genericProgram, `Corpus.sum, `Corpus.fibonacci,
      `Corpus.countdown, `Corpus.updateTicket, `List.map, `String.length] do
    let d ← CompilerM.run (toDecl n)
    logInfo (← ppDecl' d .base)
