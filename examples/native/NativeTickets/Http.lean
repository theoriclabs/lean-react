import NativeTickets.Storage
import NativeTickets.Registration

namespace NativeTickets
open Ontology Contract Examples.Tickets Examples.Tickets.Contracts

abbrev HttpReply := LeanAppNative.HttpReply
abbrev HttpReply.mk (status : Nat) (body : Lean.Json) : HttpReply := ⟨status, body⟩
def HttpReply.toJson (reply : HttpReply) : Lean.Json := LeanAppNative.HttpReply.toJson reply

/-- Compatibility metadata helper; dispatch itself uses the approved application. -/
def operationForPath (path : String) : Option (OperationId × OperationKind) := do
  let ops ← publicOperations.toOption
  let metadata ← (approvedMetadata ops).find? (·.http.path == path)
  pure (metadata.operation.identity, metadata.operation.kind)

/-- Socket-free local fixture wrapper around the reusable application dispatcher. -/
def dispatch (ops : PublicOperations) (store : Store) (method path body : String) : IO HttpReply := do
  match makeServer ops store.service with
  | .error _ => pure ⟨500, protocolResponse "application.invalid_config"⟩
  | .ok server => server.dispatch localFixtureContext method path body

def handler (ops : PublicOperations) (store : Store) (request : Std.Http.Request Std.Http.Body.Stream) :
    Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) :=
  match makeServer ops store.service with
  | .error _ => LeanAppNative.respond ⟨500, protocolResponse "application.invalid_config"⟩
  | .ok server => server.handler (fun _ => pure localFixtureContext) request

def loadOperations : IO PublicOperations :=
  match publicOperations with
  | .ok ops => pure ops
  | .error errors => throw (IO.userError (reprStr errors))

def runServer (port : UInt16) (path : System.FilePath) : IO UInt32 := do
  let ops ← loadOperations
  let store ← Store.open path
  let server ← match makeServer ops store.service with
    | .ok server => pure server
    | .error errors => throw (IO.userError (reprStr errors))
  let address : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port }
  Std.Async.Async.block do
    let runtime ← server.serve address (fun _ => pure localFixtureContext)
    let some address := runtime.localAddr | throw (IO.userError "server has no local address")
    IO.eprintln (Lean.Json.mkObj [("event", .str "tickets.ready"),
      ("host", .str "127.0.0.1"), ("port", Lean.toJson address.port.toNat)]).compress
    runtime.waitShutdown
  pure 0

end NativeTickets
