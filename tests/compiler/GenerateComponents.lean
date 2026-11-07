import LeanJS
import LeanContract.Generate
import tests.compiler.Components
open Lean Ontology Contract ComponentSpike

private def payloadCodec : Validation (Codec Payload) :=
  Codec.record ⟨"component-spike", "Payload"⟩ <|
    (RecordFields.pure Payload.mk)
      |>.apply (RecordFields.field "title" Codec.string Payload.title)
      |>.apply (RecordFields.field "count" Codec.nat Payload.count)
      |>.apply (RecordFields.field "enabled" Codec.bool Payload.enabled)

run_meta do
  let roots := #[`ComponentSpike.view, `ComponentSpike.mappedView,
    `ComponentSpike.counterChild, `ComponentSpike.textChild,
    `ComponentSpike.embeddedView, `ComponentSpike.mappedEmbeddedView,
    `ComponentSpike.embeddedInit, `ComponentSpike.embeddedNat, `ComponentSpike.embeddedText,
    `ComponentSpike.recursiveChild,
    `ComponentSpike.update, `ComponentSpike.board, `ComponentSpike.deep]
  LeanJS.writeModule "tests/compiler/components-generated.mjs" roots

  -- The unsupported path is a recorded result of the spike, not a skipped test. If
  -- FromJson becomes portable, update this decision and exercise that path in JS too.
  let rejection ← try
    let _ ← LeanJS.compile #[`ComponentSpike.decodePayload]
    pure (none : Option String)
  catch e => pure (some (← e.toMessageData.toString))
  let some diagnostic := rejection
    | throwError "FromJson now compiles: replace the P0 fallback and add generated decoder assertions"
  for needle in ["unsupported native extern operation", "ComponentSpike.decodePayload ->",
      "ComponentSpike.instFromJsonPayload", "Lean.Name.beq"] do
    unless (diagnostic.splitOn needle).length > 1 do
      throwError "Unexpected FromJson rejection (missing {needle}): {diagnostic}"
  IO.FS.writeFile "tests/compiler/components-json-generated.json" <| (Json.mkObj [
    ("status", .str "rejected"), ("fallback", .str "generated-codecs"),
    ("diagnostic", .str diagnostic)]).compress

  let .ok codec := payloadCodec | throwError "Invalid Payload codec"
  let .ok operation := Operation.create .query ⟨"component-spike", "payload", "1"⟩
    Codec.unit codec Codec.unit | throwError "Invalid Payload operation"
  let .ok codecs := Http.codecs | throwError "Invalid envelope codecs"
  Generate.emitClient [⟨operation.describe, { path := "/spike/payload" }, {}⟩] codecs []
    "tests/compiler/components-client-generated" (runtime := "#leancontract")
  let value : Payload := ⟨"λ🧪", 2^128 + 9007199254740993, true⟩
  IO.FS.writeFile "tests/compiler/components-native-generated.json" (codec.encode value).compress
