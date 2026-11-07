/- A component's `update` must handle every error the endpoint declares (Components P6):
`alreadyStarted` is missing. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact.Program

inductive Msg where
  | go (party : Ref Party)
  | answered (result : Contract.CallResult Unit RsvpError)

def update (client : Contract.Interpreter LeanReact.Action) : Msg → String → String × Cmd Msg
  | .go party, s => (s, Cmd.callBound client (api.rsvp party) .answered)
  | .answered (.ok ()), _ => ("going", .none)
  | .answered (.error (.domain .notFound)), _ => ("gone", .none)
  | .answered (.error .unauthenticated), _ => ("sign in", .none)
  | .answered (.error .forbidden), _ => ("forbidden", .none)
  | .answered (.error (.transport _)), _ => ("offline", .none)
  | .answered (.error (.protocol _)), _ => ("protocol", .none)
  | .answered (.error (.decode _)), _ => ("decode", .none)
  | .answered (.error (.incompatible _)), _ => ("incompatible", .none)
  | .answered (.error .cancelled), _ => ("cancelled", .none)
