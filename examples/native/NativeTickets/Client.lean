import Examples.Tickets.Contracts
import LeanHttp

namespace NativeTickets
open Ontology Contract Examples.Tickets.Contracts

/-- Explicitly decodes `.status` responses: LeanHttp.requestAs does not decode non-2xx. -/
def decodeOutcome (ops : PublicOperations) (request : WireRequest)
    (outcome : LeanHttp.Outcome Lean.Json) : CallResult WireResponse Empty :=
  match outcome with
  | .ok body response => decodeHttpResponse ops request response.statusCode.toNat body
  | .status response =>
    match (LeanHttp.FromBody.fromBody response.headers response.body : Except String Lean.Json) with
    | .ok body => decodeHttpResponse ops request response.statusCode.toNat body
    | .error _ => .error (.decode (ValidationErrors.single "decode.invalid_json_response"))
  | .decode message _ => .error (.decode (ValidationErrors.single "decode.invalid_json_response" [] [("detail", message)]))
  | .transport error => .error (.transport ⟨s!"curl.{error.code.toUInt32}", error.message⟩)

def clientTransport (ops : PublicOperations) (port : UInt16) : Transport IO where
  send request := do
    let path := if request.operation.name == "list" then "list" else "save"
    let uri := Std.Http.URI.parse! s!"http://127.0.0.1:{port}/api/tickets/{path}"
    let outcome : LeanHttp.Outcome Lean.Json ← LeanHttp.requestAs {
      method := .post, uri := .absolute uri, body := .json (encodeRequest ops request),
      redirects := .never, timeouts := { connect := .ofNat 2000, total := .ofNat 5000 } }
    pure (decodeOutcome ops request outcome)

end NativeTickets
