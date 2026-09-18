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

/-- The generated symbol of a declaration, as `LeanJS.Compiler` spells it. -/
private def symbol (n : Name) : String :=
  "n" ++ String.join (n.toString.toList.map fun c => "_" ++ toString c.toNat)

private def count (haystack needle : String) : Nat := (haystack.splitOn needle).length - 1

-- Self tail calls become `while (true)` loops; other recursion keeps its direct call.
run_meta do
  -- The embedded runtime has its own loops; count only compiled declarations.
  let runtime ← LeanJS.compile #[]
  let fresh (js needle : String) := count js needle - count runtime needle
  for n in [`Corpus.sumAcc, `Corpus.countLoop, `Corpus.sumEven, `Corpus.sumWhere.go] do
    let js ← LeanJS.compile #[n]
    let body := (js.splitOn s!"const {symbol n} = $lazy(")[1]!
    unless body.startsWith s!"() => $fn(2, (v0, v1) => \{\nwhile (true) \{\n" do
      throwError "{n} should compile to a parameter-rebinding loop:\n{body.take 200}"
    unless count js s!"$app({symbol n}(), " == 0 do throwError "{n} still calls itself"
    unless count body "continue;" > 0 do throwError "{n} never continues its loop"
  let js ← LeanJS.compile #[`Corpus.sumEven]
  unless count js "return new $Tail([" == 1 && count js "instanceof $Tail" == 1 do
    throwError "sumEven should unwind its join point through one $Tail request"
  for n in [`Corpus.sum, `Corpus.fibonacci, `Corpus.countdown, `Corpus.services] do
    let js ← LeanJS.compile #[n]
    unless fresh js "while (true)" == 0 && fresh js "$Tail" == 0 do
      throwError "{n} has no self tail call and must not be lowered to a loop"
  unless count (← LeanJS.compile #[`Corpus.sum]) s!"$app({symbol `Corpus.sum}(), " == 1 do
    throwError "Corpus.sum keeps its direct recursive call"
