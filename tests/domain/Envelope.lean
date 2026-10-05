/- The decision-5 reply envelope (`{"ok": v}` / `{"error": "ctor"}` /
   `{"error": {"tag": ctor, …fields}}`), alongside the unchanged default `Contract.Http`
   envelope. Uses the published post types and their derived codecs. -/
import tests.domain.PostPart1
import LeanContract.Envelope
import LeanContract.Http
open LeanApp.Domain Ontology Contract

namespace EnvelopeChecks

private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw (IO.userError ("FAIL: " ++ label))
private def parsed (value : Validation A) : IO A :=
  match value with | .ok value => pure value | .error _ => throw (IO.userError "fixture value rejected")

def main : IO Unit := do
  let errors := Wire.codec (α := RsvpError)
  let refs := Wire.codec (α := Ref Party)
  let seven ← parsed (Ref.parse (T := Party) "7")
  -- Encoding.
  check "ok" ((Envelope.ok refs seven).compress == "{\"ok\":" ++ (refs.encode seven).compress ++ "}")
  check "ok unit" ((Envelope.ok (Wire.codec (α := Unit)) ()).compress == "{\"ok\":null}")
  check "payload-free domain error" ((Envelope.domainError errors .alreadyStarted).compress == "{\"error\":\"alreadyStarted\"}")
  check "framework error" ((Envelope.frameworkError .unauthorized).compress == "{\"error\":\"unauthorized\"}")
  -- Payload-carrying constructor (derived variant codec of the post's GuestList).
  let lists := Wire.codec (α := GuestList)
  let asha ← parsed (Name.parse "Asha")
  check "payload error" ((Envelope.domainError lists (.visible [{ name := asha }])).compress ==
    "{\"error\":{\"guests\":[{\"name\":\"Asha\"}],\"tag\":\"visible\"}}")
  -- Decoding through the endpoint's own codecs.
  match Envelope.decode refs errors (Envelope.ok refs seven) with
  | .ok (.ok value) => check "decode ok" (value.key == "7")
  | _ => check "decode ok" false
  match Envelope.decode refs errors (Envelope.domainError errors .notFound) with
  | .ok (.domain .notFound) => pure ()
  | _ => check "decode domain" false
  match Envelope.decode refs errors (Envelope.frameworkError .unauthorized) with
  | .ok (.framework .unauthorized) => pure ()
  | _ => check "decode framework" false
  match Envelope.decode refs lists (Envelope.domainError lists (.visible [{ name := asha }])) with
  | .ok (.domain (.visible [guest])) => check "decode payload error" (guest.name.value == "Asha")
  | _ => check "decode payload error" false
  -- `notFound` is both a domain constructor and a framework code: the HTTP status decides.
  match Envelope.decodeAt refs errors (Envelope.frameworkError .notFound) (frameworkStatus := true) with
  | .ok (.framework .notFound) => pure ()
  | _ => check "framework status disambiguates" false
  match Envelope.decode refs errors (Envelope.frameworkError .notFound) with
  | .ok (.domain .notFound) => pure ()
  | _ => check "domain preferred without a framework status" false
  -- Strictness.
  check "unknown code rejected" (match Envelope.decode refs errors (.mkObj [("error", .str "bogus")]) with | .error _ => true | _ => false)
  check "mixed keys rejected" (match Envelope.decode refs errors (.mkObj [("ok", .null), ("error", .str "x")]) with | .error _ => true | _ => false)
  check "ok payload checked" (match Envelope.decode refs errors (.mkObj [("ok", .str "7")]) with | .error _ => true | _ => false)
  -- Decision 15 public values: bare-integer references, RFC 3339 times, no type/scope noise.
  check "ref is a bare integer" ((Envelope.ok refs seven).compress == "{\"ok\":7}")
  let date ← parsed (Instant.ofEpochSeconds 1792263600)
  check "time is RFC 3339 UTC" ((Wire.codec (α := Time)).encode date == .str "2026-10-17T19:00:00Z")
  check "time round trip" (((Wire.codec (α := Time)).decode (.str "2026-10-17T19:00:00Z")).toOption.map (·.value) == some 1792263600)
  check "time old form accepted" (((Wire.codec (α := Time)).decode (JsonWire.tagged "int" (.str "1792263600"))).toOption.map (·.value) == some 1792263600)
  check "time noncanonical rejected" ((Wire.codec (α := Time)).decode (.str "2026-10-17T19:00:00.000Z") |>.toOption |>.isNone)
  check "ref old form accepted" ((refs.decode (refCodec.encode seven)).toOption.map (·.key) == some "7")
  let other ← parsed (Ref.parse (T := Party) "7" "tenant")
  check "non-default scope never crosses" ((refs.decode (refs.encode other)).toOption.isNone)
  check "ref must be a positive integer" ((refs.decode (.num ⟨-3, 0⟩)).toOption.isNone && (refs.decode (.str "7")).toOption.isNone)
  check "session is the profile ref" ((Wire.codec (α := Session)).encode (Trusted.session seven) == .num ⟨7, 0⟩)
  -- Lean clients decode both envelopes during the transition.
  let codecs ← parsed Http.codecs
  match Envelope.decodeAny refs errors 200 (Http.successResponse codecs ⟨"domain", "rsvp", "1"⟩ (refs.encode seven)) with
  | .ok (.ok value) => check "old success envelope" (value.key == "7")
  | _ => check "old success envelope" false
  match Envelope.decodeAny refs errors 401 (.mkObj [("tag", .str "unauthenticated")]) with
  | .ok (.framework .unauthorized) => pure ()
  | _ => check "old unauthenticated" false
  match Envelope.decodeAny refs errors 404 (Envelope.frameworkError .notFound) with
  | .ok (.framework .notFound) => pure ()
  | _ => check "new framework notFound by status" false
  match Envelope.decodeAny refs errors 422 (Envelope.domainError errors .notFound) with
  | .ok (.domain .notFound) => pure ()
  | _ => check "new domain notFound by status" false
  -- The default Contract.Http envelope is unchanged ("tag"/"value").
  check "default envelope untouched" ((Http.successResponse codecs ⟨"a", "b", "1"⟩ .null).getObjValD "tag" == Lean.Json.str "success")
  IO.println "PASS decision-5 envelope: ok / domain / payload / framework, strict decoding, default unchanged"

end EnvelopeChecks

def main := EnvelopeChecks.main
