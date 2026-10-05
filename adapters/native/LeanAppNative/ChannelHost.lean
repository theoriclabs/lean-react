import LeanAppNative.Channels
import LeanAppNative.Auth.Store
import LeanAppNative.Auth.Crypto
import LeanWs

namespace LeanAppNative.Channels
open LeanApi.Publication
open LeanAppNative.Auth
open Contract (Frame CloseReason WireRequest Topic SubId)
open Std Std.Async Std.Http

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

/-- The session cookie the HTTP host issues: `__Host-` outside development. -/
def sessionCookieName (development : Bool := false) : String :=
  if development then "leanapp_session" else "__Host-leanapp_session"

/-- The session token under exactly `name`, as the HTTP host reads it. Any other
    cookie name is ignored, and a duplicated cookie is treated as absent, so a
    tossed `leanapp_session` cannot stand in for the `__Host-` cookie. -/
def cookieToken (headers : Headers) (name : String := sessionCookieName) : Option String := do
  let raw ← (headers.get? (Header.Name.ofString! "cookie")).map (·.value)
  let fields := raw.splitOn ";" |>.map (fun item => item.trimAscii.toString.splitOn "=")
  let [entry] := fields.filter (fun item => item.head? == some name) | none
  let [_, token] := entry | none
  if tokenShape token then some token else none

private inductive Incoming where
  | msg (m : Option LeanWs.Message)
  | timeout

private def nextMessage (ws : LeanWs.Session) (budgetMs : Option Nat) : Async Incoming := do
  match budgetMs with
  | none => return .msg (← ws.recv)
  | some 0 => return .timeout
  | some ms =>
    Selectable.one #[
      .case ws.recvSelector (fun m => pure (.msg m)),
      .case (← Selector.sleep (Time.Millisecond.Offset.ofNat ms)) (fun _ => pure .timeout)]

/-- Shared recv loop. `closePolicy` turns a CSRF/hello failure into WebSocket 1008.
    `revalidate` re-checks the session every `limits.revalidateMs`, so a socket
    loses its authority when the session expires, not only on explicit logout. -/
private def pump (ws : LeanWs.Session) (session : Session) (registry : Registry)
    (channels : List (ApprovedChannel IO)) (context : RequestContext) (csrf : String)
    (onCall : Option (RequestContext → WireRequest → IO Lean.Json))
    (onClose : RequestContext → List (Topic × SubId) → IO Unit)
    (helloTimeoutMs : Nat) (closePolicy : Bool)
    (revalidate : Option (IO Bool) := none) : Async Unit := do
  let started ← IO.monoMsNow
  let every := session.limits.revalidateMs
  let revalidate := if every == 0 then none else revalidate
  let nextCheck ← IO.mkRef (started + every)
  try
    repeat
      let helloDue : Option Nat ← do
        if helloTimeoutMs == 0 || (← session.helloed.get) then pure none
        else pure (some (started + helloTimeoutMs))
      let checkDue : Option Nat ← do
        if revalidate.isSome then pure (some (← nextCheck.get)) else pure none
      let due := match helloDue, checkDue with
        | some a, some b => some (min a b)
        | some a, none => some a
        | none, b => b
      let now ← IO.monoMsNow
      match ← nextMessage ws (due.map (· - now)) with
      | .timeout =>
        let now ← IO.monoMsNow
        if helloDue.any (now ≥ ·) then
          if closePolicy then
            discard <| ws.close .policyViolation "hello"
          else
            discard <| session.push (.closed ⟨0⟩ .session)
          break
        if let some check := revalidate then
          unless ← (try check catch _ => pure false) do
            discard <| session.push (.closed ⟨0⟩ .session)
            discard <| ws.close .policyViolation "session"
            break
          nextCheck.set (now + every)
      | .msg none => break
      | .msg (some (LeanWs.Message.text text)) =>
        match decodeText text with
        | none =>
          discard <| session.push (.closed ⟨0⟩ .session)
        | some frame =>
          match ← session.drive registry channels context csrf frame onCall with
          | .cont => pure ()
          | .stop => break
          | .policy =>
            if closePolicy then
              discard <| ws.close .policyViolation "csrf"
            else
              discard <| session.push (.closed ⟨0⟩ .session)
            break
      | .msg (some (LeanWs.Message.binary _)) =>
        discard <| session.push (.closed ⟨0⟩ .session)
        break
  finally
    let topics ← session.topics
    session.release registry
    try onClose context topics catch _ => pure ()

/-- Bind `addr` and accept Channels sessions with a fixed context (tests). -/
def Host.listenWith (addr : Std.Net.SocketAddress) (registry : Registry)
    (channels : List (ApprovedChannel IO)) (context : RequestContext)
    (expectedCsrf : String)
    (onCall : Option (RequestContext → WireRequest → IO Lean.Json) := none)
    (onClose : RequestContext → List (Topic × SubId) → IO Unit := fun _ _ => pure ())
    (limits : SessionLimits := { helloTimeoutMs := 0 })
    (config : LeanWs.ServerConfig := { sendTimeoutMs := 0 }) :
    IO Host :=
  Async.block do
    let server ← LeanWs.Server.serve addr config
      (fun req _ => pure (LeanWs.Handshake.server req { subprotocols := [protocol] }))
      (fun ws _accept => do
        let session ← Session.new limits
        Session.attach session (sendFrame ws)
        pump ws session registry channels context expectedCsrf onCall onClose
          limits.helloTimeoutMs false)
    return { server, registry }

private structure Bound where
  id : Nat
  digest : String
  actor : String
  session : Session
  ws : LeanWs.Session
  alive : IO.Ref Bool

/-- Bind `addr` and accept Channels sessions. Cookie → session at the upgrade;
    `hello {csrf}` must match within `helloTimeoutMs` or the socket closes 1008. -/
def Host.listen (addr : Std.Net.SocketAddress) (registry : Registry)
    (channels : List (ApprovedChannel IO)) (auth : Service)
    (origin : String → Bool)
    (onCall : Option (RequestContext → WireRequest → IO Lean.Json) := none)
    (onClose : RequestContext → List (Topic × SubId) → IO Unit := fun _ _ => pure ())
    (limits : SessionLimits := {})
    (config : LeanWs.ServerConfig := { sendTimeoutMs := 0 })
    (cookieName : String := sessionCookieName) :
    IO Host := do
  let bound ← IO.mkRef ([] : List Bound)
  let nextBound ← IO.mkRef (0 : Nat)
  auth.onInvalidation fun ev => do
    let all ← bound.get
    for b in all do
      if ← b.alive.get then
        let hit := match ev with
          | .digest d => d == b.digest
          | .actor a => a == b.actor
        if hit then
          b.alive.set false
          discard <| b.session.push (.closed ⟨0⟩ .session)
          try Async.block (b.ws.close .policyViolation "session") catch _ => pure ()
  Async.block do
    let server ← LeanWs.Server.serve addr config
      (fun req _ => do
        match LeanWs.Handshake.server req {
            subprotocols := [protocol]
            checkOrigin := fun
              | some o => origin o
              | none => false } with
        | .error e => return .error e
        | .ok accept =>
          let some token := cookieToken req.headers cookieName | return .error .unauthorized
          match ← (try auth.session token catch _ => pure (.error .internal)) with
          | .ok _ => return .ok accept
          | .error _ => return .error .unauthorized)
      (fun ws accept => do
        let some token := cookieToken accept.request.headers cookieName | do
          discard <| ws.close .policyViolation "session"
          return
        match ← (try auth.session token catch _ => pure (.error .internal)) with
        | .error _ => discard <| ws.close .policyViolation "session"
        | .ok (user, csrf) =>
          let digest ← Crypto.digestToken token
          let requestId :=
            ((accept.request.headers.get? (Header.Name.ofString! "x-request-id")).map (·.value)).getD "ws"
          let context := TrustedNative.issueContext ⟨user.actor, user.tenant, user.generation⟩ requestId
          let session ← Session.new limits
          Session.attach session (sendFrame ws)
          let flag ← IO.mkRef true
          let id ← nextBound.modifyGet fun n => (n, n + 1)
          bound.modify ({ id, digest, actor := user.actor, session, ws, alive := flag } :: ·)
          let stillValid : IO Bool := do
            match ← auth.session token with
            | .ok (current, _) => return current.actor == user.actor
            | .error _ => return false
          try
            pump ws session registry channels context csrf onCall onClose
              limits.helloTimeoutMs true (revalidate := some stillValid)
          finally
            flag.set false
            bound.modify (·.filter (·.id != id)))
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
