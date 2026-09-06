import NativeTickets.Storage
import Std.Http

namespace NativeTickets
open Ontology Contract Examples.Tickets Examples.Tickets.Contracts

structure HttpReply where
  status : Nat
  body : Lean.Json

def HttpReply.toJson (reply : HttpReply) : Lean.Json :=
  .mkObj [("status", Lean.toJson reply.status), ("body", reply.body)]

/-- Pure routing metadata, with only the two explicit public operation identities. -/
def operationForPath : String → Option (OperationId × OperationKind)
  | "/api/tickets/list" => some (listIdentity, .query)
  | "/api/tickets/save" => some (saveIdentity, .command)
  | _ => none

/-- Socket-free entry point used verbatim by both HTTP and executable protocol fixtures. -/
def dispatch (ops : PublicOperations) (store : Store) (method path body : String) : IO HttpReply := do
  if path == "/api/manifest" && method == "GET" then return ⟨200, ops.manifest⟩
  let some (expected, expectedKind) := operationForPath path
    | return ⟨404, protocolResponse "route.not_found"⟩
  if method != "POST" then return ⟨405, protocolResponse "method.not_allowed"⟩
  let decoded : Validation WireRequest := do
    let json ← (Lean.Json.parse body).mapError fun _ => ValidationErrors.single "decode.invalid_json"
    decodeRequest ops json
  let request ← match decoded with
    | .ok value => pure value
    | .error errors => return ⟨400, decodeErrorResponse ops errors⟩
  if request.operation != expected then
    return ⟨409, incompatibleResponse ops expected request.operation⟩
  if request.kind != expectedKind then return ⟨400, protocolResponse "operation.kind_mismatch"⟩
  try
    if expectedKind == .query then
      match ops.list.inputCodec.decode request.input with
      | .error errors => return ⟨400, decodeErrorResponse ops errors⟩
      | .ok () =>
        let values ← store.service.list
        return ⟨200, successResponse ops expected (ops.list.outputCodec.encode values)⟩
    else
      match ops.save.inputCodec.decode request.input with
      | .error errors => return ⟨400, decodeErrorResponse ops errors⟩
      | .ok input =>
        match ← store.service.save input with
        | .ok saved => return ⟨200, successResponse ops expected (ops.save.outputCodec.encode saved)⟩
        | .error error =>
          let status := match error with | .notFound => 404 | .conflict _ => 409
          return ⟨status, domainResponse ops expected error⟩
  catch _ => return ⟨500, protocolResponse "storage.failed"⟩

private def respond (reply : HttpReply) : Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let status := (Std.Http.Status.ofCode none reply.status.toUInt16).getD .internalServerError
  let response ← (Std.Http.Response.withStatus status).json reply.body.compress
  pure { line := response.line, body := Std.Http.Body.Any.ofBody response.body, extensions := response.extensions }

def handler (ops : PublicOperations) (store : Store) (request : Std.Http.Request Std.Http.Body.Stream) :
    Std.Async.ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let bytes ← Std.Http.Body.Stream.readAll request.body
  let some body := String.fromUTF8? bytes
    | return ← respond ⟨400, decodeErrorResponse ops (ValidationErrors.single "decode.invalid_utf8")⟩
  let method := toString request.line.method
  let path := "/" ++ String.intercalate "/" request.line.uri.path.toDecodedSegments.toList
  -- SQLite and mutex waiting run on a worker, never the event-loop continuation.
  let task ← IO.asTask (dispatch ops store method path body) (prio := .dedicated)
  let reply ← Std.Async.Async.ofAsyncTask task
  respond reply

def loadOperations : IO PublicOperations :=
  match publicOperations with
  | .ok ops => pure ops
  | .error errors => throw (IO.userError (reprStr errors))

def runServer (port : UInt16) (path : System.FilePath) : IO UInt32 := do
  let ops ← loadOperations
  let store ← Store.open path
  let address : Std.Net.SocketAddress := .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port }
  Std.Async.Async.block do
    let server ← Std.Http.Server.serve address (Std.Http.Server.Handler.ofFn (handler ops store))
      { generateDate := false, maxBodySize := 1024 * 1024, maxConnections := 64 }
    let some address := server.localAddr | throw (IO.userError "server has no local address")
    IO.eprintln (Lean.Json.mkObj [("event", .str "tickets.ready"),
      ("host", .str "127.0.0.1"), ("port", Lean.toJson address.port.toNat)]).compress
    server.waitShutdown
  pure 0

end NativeTickets
