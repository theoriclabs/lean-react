import tests.compiler.Corpus
open Lean
run_meta do
  let a ← LeanJS.compile #[`Corpus.services, `Corpus.fibonacci]
  let b ← LeanJS.compile #[`Corpus.services, `Corpus.fibonacci]
  unless a == b do throwError "Code generation is nondeterministic within one environment"
  let a ← LeanJS.compileArtifacts #[`Corpus.services, `Corpus.fibonacci]
  let b ← LeanJS.compileArtifacts #[`Corpus.services, `Corpus.fibonacci]
  unless a.declarations == b.declarations && a.manifest.compress == b.manifest.compress do
    throwError "Declaration/manifest generation is nondeterministic"
