import NativeTickets.Registration
import LeanAppNative.Client

namespace NativeTickets
open Ontology Contract Examples.Tickets.Contracts

def makeClient (ops : PublicOperations) (origin : String) : Validation LeanAppNative.Client :=
  LeanAppNative.Client.create origin (approvedMetadata ops) ops.httpCodecs ops.errorStatuses

/-- Compatibility entry point; both successful and non-2xx bodies use the common decoder. -/
def decodeOutcome (ops : PublicOperations) (request : WireRequest)
    (outcome : LeanHttp.Outcome Lean.Json) : CallResult WireResponse Empty :=
  match makeClient ops "http://127.0.0.1" with
  | .ok client => client.decodeOutcome request outcome
  | .error errors => .error (.decode errors)

def clientTransport (ops : PublicOperations) (port : UInt16) : Transport IO :=
  match makeClient ops s!"http://127.0.0.1:{port}" with
  | .ok client => client.transport
  | .error errors => { send := fun _ => pure (.error (.decode errors)) }

end NativeTickets
