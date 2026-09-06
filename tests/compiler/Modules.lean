import tests.compiler.Corpus
open Lean LeanJS

private def expectRejection (options : LeanJS.Options) (needle : String) : CoreM Unit := do
  let failure ← try
    let _ ← compileArtifacts #[`Corpus.services] options
    pure (none : Option String)
  catch error => pure (some (← error.toMessageData.toString))
  let some message := failure | throwError "Expected library rejection: {needle}"
  unless (message.splitOn needle).length > 1 do throwError "Unexpected diagnostic: {message}"

run_meta do
  let id : LibraryId := ⟨"example", "1.0.0", "Services"⟩
  let producer ← compileArtifacts #[`Corpus.services] { library := some id }
  let dependency ← ofExcept (producer.asImport "./producer.mjs")
  let consumer ← compileArtifacts #[`Corpus.services] { libraries := #[dependency] }
  let declarations ← ofExcept (consumer.manifest.getObjValAs? (Array Json) "declarations")
  unless declarations.size == 1 do throwError "Imported declarations must not be recompiled"
  let again ← compileArtifacts #[`Corpus.services] { libraries := #[dependency] }
  unless consumer.javascript == again.javascript do throwError "Linked output is nondeterministic"
  let signature := dependency.interface.exports[0]!
  for bad in #[{ signature with arity := signature.arity + 1 }, { signature with typeHash := "stale" }] do
    expectRejection { libraries := #[{ dependency with interface.exports := #[bad] }] } "signature mismatch"
  expectRejection { libraries := #[{ dependency with interface.abi := "future" }] } "incompatible library"
  expectRejection { libraries := #[{ dependency with interface.lean := "other" }] } "incompatible library"
  expectRejection { libraries := #[dependency, dependency] } "duplicate library"
  expectRejection { libraries := #[dependency,
    { dependency with module := "./other.mjs", interface.id.packageName := "other" }] } "ambiguous library ownership"
  expectRejection { library := some id, libraries := #[dependency] } "own identity"
  expectRejection { libraries := #[dependency], intrinsics := #[⟨`Corpus.services, "./native.mjs", "services", 1⟩] }
    "library/intrinsic overlap"
  logInfo "PASS library interfaces, direct imports, deterministic linking, and incompatible/ambiguous ownership rejection"
