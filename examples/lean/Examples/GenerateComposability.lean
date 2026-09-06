import Examples.ReactCompiler
import Examples.Collections
import Examples.Libraries.App

open Lean

private def options : LeanJS.Options := { Examples.reactOptions with
  intrinsics := Examples.reactIntrinsics.push {
    leanName := `Examples.Libraries.instTypeNameFormatter
    module := Examples.reactModule
    exportName := "erased"
    arity := 0
  } }

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/collections.mjs"
    #[`Examples.Collections.App, `Examples.Collections.parseRows] options
  LeanJS.writeModule "examples/generated/shared.mjs"
    #[`Examples.Libraries.formatter, `Examples.Libraries.otherFormatter]
    { options with library := some ⟨"example-services", "1.0.0", "Shared"⟩ }

run_meta do
  -- Read the producer's manifest just as a build in another package/process would.
  let shared ← LeanJS.readLibrary "examples/generated/shared.manifest.json" "./shared.mjs"
  LeanJS.writeModule "examples/generated/provider.mjs"
    #[`Examples.Libraries.Provider, `Examples.Libraries.providerContext]
    { options with libraries := #[shared], library := some ⟨"example-provider", "1.0.0", "Provider"⟩ }
  LeanJS.writeModule "examples/generated/consumer.mjs"
    #[`Examples.Libraries.Greeting, `Examples.Libraries.OtherGreeting, `Examples.Libraries.consumerContext]
    { options with libraries := #[shared], library := some ⟨"example-consumer", "1.0.0", "Consumer"⟩ }

run_meta do
  let provider ← LeanJS.readLibrary "examples/generated/provider.manifest.json" "./provider.mjs"
  let consumer ← LeanJS.readLibrary "examples/generated/consumer.manifest.json" "./consumer.mjs"
  LeanJS.writeModule "examples/generated/libraries.mjs" #[`Examples.Libraries.App]
    { options with libraries := #[provider, consumer] }
  LeanJS.writeModule "examples/generated/automatic-context.mjs" #[`Examples.Libraries.Automatic] options
