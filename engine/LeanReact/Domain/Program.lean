import LeanReact.Domain.App
import LeanReact.Program.Cmd

/-! # Typed server calls from declarative components (P6)

```
inductive Msg where
  | going
  | answered (result : Contract.CallResult Unit RsvpError)

def update (client : Contract.Interpreter Action) : Msg → Model → Model × Cmd Msg
  | .going, m => (m, Cmd.callBound client (api.rsvp m.party) .answered)
  | .answered (.ok ()), m => …
  | .answered (.error (.domain .notFound)), m => …
  | .answered (.error (.domain .alreadyStarted)), m => …   -- every declared error, or it fails to compile
  | .answered (.error _), m => …                            -- transport, 401, decoding
```

A call is typed by the endpoint it targets: the message receives
`Contract.CallResult O E = Except (CallError E) O`, the endpoint's declared output and its closed
domain error, so `update` must handle every failure the server declares. Transport failures,
401/403 and malformed answers are the other `CallError` constructors. The client is the same
`Contract.Interpreter Action` an `App` is mounted with (the generated client over `fetch`). -/

namespace LeanReact.Program.Cmd
open LeanApi.Core LeanReact.Domain

/-- Call `endpoint` with `input`; the typed result arrives as a message. -/
def call (client : Contract.Interpreter Action) (endpoint : Endpoint I E O) (input : I)
    (toMsg : Contract.CallResult O E → Msg) : Cmd Msg :=
  .task ((client.call endpoint.operation.contract input).map (some ∘ toMsg))

/-- Call an endpoint whose inputs are its given path fields and the actor
(`api.rsvp party`, or an actor-only endpoint); the typed result arrives as a message. A path
field that does not decode is a `.decode` failure. -/
def callBound (client : Contract.Interpreter Action) (endpoint : Endpoint I E O)
    (toMsg : Contract.CallResult O E → Msg) : Cmd Msg :=
  match endpointInput endpoint.operation.contract.inputCodec (endpointBindings endpoint []) with
  | .ok input => call client endpoint input toMsg
  | .error errors => .task (pure (some (toMsg (.error (.decode errors)))))

end LeanReact.Program.Cmd
