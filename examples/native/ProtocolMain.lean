import NativeTickets.Http

/-- One JSON envelope per stdin line; no sockets or arbitrary database commands. -/
def main (args : List String) : IO UInt32 := do
  let [path] := args | throw (IO.userError "usage: tickets_protocol <sqlite-file>")
  let ops ← NativeTickets.loadOperations
  let store ← NativeTickets.Store.open path
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    let request := do
      let json ← Lean.Json.parse line
      let method ← json.getObjValAs? String "method"
      let path ← json.getObjValAs? String "path"
      let body ← json.getObjVal? "body"
      pure (method, path, body.compress)
    let reply ← match request with
      | .ok (method, path, body) => NativeTickets.dispatch ops store method path body
      | .error _ => pure (NativeTickets.HttpReply.mk 400
          (Examples.Tickets.Contracts.protocolResponse "fixture.invalid_envelope"))
    output.putStrLn reply.toJson.compress
    output.flush
  pure 0
