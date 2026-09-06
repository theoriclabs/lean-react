import tests.compiler.Corpus
open Lean
#lean_js "tests/compiler/iteration.mjs" [Corpus.scanId, Corpus.scanExcept, Corpus.arrayFoldM, Corpus.arrayFind]
#lean_js "tests/compiler/generated.mjs" [Corpus.useCapture, Corpus.capture, Corpus.twice, Corpus.services, Corpus.runService, Corpus.ticketScore, Corpus.updateTicket, Corpus.titleCheck, Corpus.statusScore, Corpus.sum, Corpus.mapCaptured, Corpus.fibonacci, Corpus.countdown, Corpus.natural, Corpus.signed, Corpus.text, Corpus.chars, Corpus.arrayWork, Corpus.arrayRead, Corpus.arrayFold, Corpus.arrayFilter, Corpus.arraySet, Corpus.observation, Corpus.programId, Corpus.programOption, Corpus.classifyText, Corpus.integerParts, Corpus.nestedOption, Corpus.bindFirst]
run_meta do
  let options : LeanJS.Options := { intrinsics := #[{
    leanName := `Corpus.nativeReference
    module := "./intrinsic.mjs"
    exportName := "nativeReference"
    arity := 3
  }] }
  IO.FS.writeFile "tests/compiler/intrinsic-generated.mjs" (← LeanJS.compile #[`Corpus.viaIntrinsic] options)
