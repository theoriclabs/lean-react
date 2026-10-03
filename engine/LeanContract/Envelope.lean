import LeanContract.Operation

/-! # The reply envelope of coordination decision 5 (NEW; no default switched)

```
success              {"ok": <value>}
domain error         {"error": "<ctor>"}                      payload-free constructor
                     {"error": {"tag": "<ctor>", …fields}}    constructor with named fields
framework error      {"error": "unauthorized"} / "badRequest" / "notFound" / …
```

These encoders/decoders sit alongside the existing `Contract.Http` envelope, which stays
the default until the coordinated switch (LeanAPI server, generated client, acceptance).
Domain values go through the operation's own checked codecs; payload-carrying error
constructors use the `{"tag", "value": {fields}}` shape produced by derived variant codecs.

A domain constructor may share its name with a framework code (`notFound`). Decoding
prefers the endpoint's domain error type; servers must pick an HTTP status that tells the
two apart (the status is passed to `Envelope.decodeAt`). -/

namespace Contract.Envelope
open Ontology

/-- Framework (non-domain) failures, by their wire code. -/
inductive Framework where
  | unauthorized
  | forbidden
  | badRequest
  | notFound
  | conflict
  | tooManyRequests
  | unavailable
  | internal
  deriving Repr, BEq, DecidableEq

def Framework.code : Framework → String
  | .unauthorized => "unauthorized"
  | .forbidden => "forbidden"
  | .badRequest => "badRequest"
  | .notFound => "notFound"
  | .conflict => "conflict"
  | .tooManyRequests => "tooManyRequests"
  | .unavailable => "unavailable"
  | .internal => "internal"

def Framework.status : Framework → Nat
  | .unauthorized => 401
  | .forbidden => 403
  | .badRequest => 400
  | .notFound => 404
  | .conflict => 409
  | .tooManyRequests => 429
  | .unavailable => 503
  | .internal => 500

def Framework.ofCode? (code : String) : Option Framework :=
  [Framework.unauthorized, .forbidden, .badRequest, .notFound, .conflict, .tooManyRequests, .unavailable, .internal].find? (·.code == code)

/-- A decoded reply: the output, a typed domain error, or a framework failure. -/
inductive Reply (Error Output : Type) where
  | ok (value : Output)
  | domain (error : Error)
  | framework (failure : Framework)
  deriving Repr, BEq

/-- `{"ok": value}` -/
def ok (codec : Codec α) (value : α) : Lean.Json :=
  .mkObj [("ok", codec.encode value)]

/-- Turn the codec's tagged form into the envelope's error payload. -/
def errorPayload (tagged : Lean.Json) : Lean.Json :=
  match tagged.getObjValD "tag", tagged.getObjValD "value" with
  | .str tag, .null => .str tag
  | .str tag, .obj fields => .mkObj (("tag", .str tag) :: fields.toArray.toList.map fun ⟨k, v⟩ => (k, v))
  | .str tag, other => .mkObj [("tag", .str tag), ("value", other)]
  | _, _ => tagged

/-- `{"error": "ctor"}` or `{"error": {"tag": "ctor", …fields}}` through the error's codec. -/
def domainError (codec : Codec ε) (error : ε) : Lean.Json :=
  .mkObj [("error", errorPayload (codec.encode error))]

/-- `{"error": "unauthorized"}` etc. -/
def frameworkError (failure : Framework) : Lean.Json :=
  .mkObj [("error", .str failure.code)]

/-- The codec's tagged form of an envelope error payload. -/
def taggedOfPayload (payload : Lean.Json) : Lean.Json :=
  match payload with
  | .str tag => JsonWire.tagged tag .null
  | .obj fields =>
    match payload.getObjValD "tag" with
    | .str tag =>
      let rest := fields.toArray.toList.filter (·.1 != "tag")
      match rest with
      | [("value", value)] => JsonWire.tagged tag value
      | _ => JsonWire.tagged tag (.mkObj (rest.map fun ⟨k, v⟩ => (k, v)))
    | _ => payload
  | other => other

/-- Decode a reply body. `status` (when known) decides an ambiguous error code: a framework
status (401/403/404 from the framework, 400, 429, 5xx) with a framework code is framework. -/
def decodeAt (output : Codec α) (error : Codec ε) (json : Lean.Json) (frameworkStatus : Bool := false) :
    Validation (Reply ε α) := do
  match json with
  | .obj fields =>
    let keys := fields.toArray.toList.map (·.1)
    if keys == ["ok"] then
      return .ok (← Codec.field "ok" output json)
    if keys == ["error"] then
      let payload ← JsonWire.get "error" json
      let framework := match payload with
        | .str code => Framework.ofCode? code
        | _ => none
      if frameworkStatus then
        if let some failure := framework then return .framework failure
      match error.decode (taggedOfPayload payload) with
      | .ok value => return .domain value
      | .error errors =>
        match framework with
        | some failure => return .framework failure
        | none => throw errors
    Validation.fail "envelope.unexpected_keys"
  | _ => Validation.fail "envelope.expected_object"

def decode (output : Codec α) (error : Codec ε) (json : Lean.Json) : Validation (Reply ε α) :=
  decodeAt output error json

/-- Decode a reply in either envelope during the transition: the decision-5 shape above, or
the milestone-1 `Contract.Http` shape (`{"operation", "tag": "success" | "domainError",
"value"}` and `{"tag": "unauthenticated" | "forbidden" | "decode" | "protocol" | …}`). The
HTTP status separates a framework code from a same-named domain constructor. -/
def decodeAny (output : Codec α) (error : Codec ε) (status : Nat) (json : Lean.Json) :
    Validation (Reply ε α) := do
  match json.getObjValD "tag" with
  | .str "success" => return .ok (← Codec.field "value" output json)
  | .str "domainError" => return .domain (← Codec.field "value" error json)
  | .str "unauthenticated" => return .framework .unauthorized
  | .str "forbidden" => return .framework .forbidden
  | .str "decode" => return .framework .badRequest
  | .str "incompatible" => return .framework .conflict
  | .str "protocol" =>
    return .framework (match status with
      | 401 => .unauthorized | 403 => .forbidden | 404 => .notFound | 409 => .conflict
      | 429 => .tooManyRequests | 503 => .unavailable | 400 => .badRequest | _ => .internal)
  | _ =>
    let framework := match json.getObjValD "error" with
      | .str code => (Framework.ofCode? code).any (·.status == status)
      | _ => false
    decodeAt output error json (frameworkStatus := framework)

/-- Encode a typed reply. -/
def encode (output : Codec α) (error : Codec ε) : Reply ε α → Lean.Json
  | .ok value => ok output value
  | .domain failure => domainError error failure
  | .framework failure => frameworkError failure

end Contract.Envelope
