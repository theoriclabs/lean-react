import LeanAppNative.Channels
import LeanWs

namespace LeanAppNative.Channels
open LeanApp
open Contract (Frame CloseReason)
open Std.Async Std.Http

/-- Subprotocol the gateway and `useChannel` advertise. -/
def protocol : String := "leanapp.v1"

structure Host where
  server : LeanWs.Server
  registry : Registry

private def sendFrame (ws : LeanWs.Session) (f : Frame) : IO Bool := do
  match ← Async.block (ws.send (LeanWs.Message.text (Frame.encode f).compress)) with
  | .ok () => return true
  | .error _ => return false

private def decodeText (text : String) : Option Frame :=
  match Lean.Json.parse text with
  | .ok json => Frame.decode json
  | .error _ => none

/-- Bind `addr` and accept Channels sessions. `onSession` runs the protocol
    machine and writes replies / published events on the socket. -/
def Host.listen (addr : Std.Net.SocketAddress) (registry : Registry)
    (channels : List (ApprovedChannel IO)) (context : RequestContext)
    (expectedCsrf : String) (config : LeanWs.ServerConfig := { sendTimeoutMs := 0 }) :
    IO Host :=
  Async.block do
    let server ← LeanWs.Server.serve addr config
      (fun req _ => pure (LeanWs.Handshake.server req { subprotocols := [protocol] }))
      (fun ws _accept => do
        let session ← Session.new
        Session.attach session (sendFrame ws)
        repeat
          match ← ws.recv with
          | none => break
          | some (LeanWs.Message.text text) =>
            match decodeText text with
            | none =>
              discard <| session.push (.closed ⟨0⟩ .session)
            | some frame =>
              session.handle registry channels context expectedCsrf frame
          | some (LeanWs.Message.binary _) =>
            discard <| session.push (.closed ⟨0⟩ .session)
            break)
    return { server, registry }

def Host.localPort (h : Host) : UInt16 :=
  match h.server.localAddr with
  | .v4 a => a.port
  | .v6 a => a.port

/-- Close every subscription, then drain sockets with 1001. -/
def Host.drain (h : Host) : IO Unit := do
  h.registry.closeAll .gone
  Async.block (LeanWs.Server.drain h.server)

end LeanAppNative.Channels
