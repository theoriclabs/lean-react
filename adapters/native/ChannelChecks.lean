import LeanAppNative.Channels
import LeanAppNative.ChannelHost
import LeanAppNative.Auth.Store
import LeanAppNative.Auth.Demo
import LeanApp.Channel
import LeanApp.Policy
import LeanWs
import LeanDb.Runtime

open LeanApp Contract
open LeanAppNative.Channels
open LeanAppNative.Auth
open Std.Http

namespace ChannelFixture

def identity : OperationId := ⟨"tickets", "watch", "1"⟩
def saveId : OperationId := ⟨"tickets", "save", "1"⟩

private def topicKey (params : Lean.Json) : String :=
  match params.getObjValAs? String "k" with | .ok k => k | _ => "1"

def approved (allow : Bool) (seen : Option (IO.Ref (Array String)) := none) : ApprovedChannel IO := {
  identity
  published := {}
  subscribe := fun ctx params => do
    if let some ref := seen then
      if let some p := ctx.principal then ref.modify (·.push p.actor)
    if ctx.principal.isNone then return .error .unauthenticated
    if !allow then return .error .forbidden
    return .ok ([Topic.doc (topicKey params)], some (.mkObj [("ok", .bool true)]))
  inbound := fun _ _ payload => pure (.ok payload)
}

def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

def roundTrip (f : Frame) : Bool :=
  (Frame.decode (Frame.encode f)).map Frame.encode == some (Frame.encode f)

private def password : String := "a sufficiently long password 🔐"
private def originOk : String := "https://app.example"

private def wsHeaders (cookie : Option String) (origin : String := originOk) : Headers :=
  let h := Headers.empty.insert! "Origin" origin
  match cookie with
  | none => h
  | some token => h.insert! "Cookie" s!"leanapp_session={token}"

private def send (ws : LeanWs.Session) (f : Frame) : Std.Async.Async Unit := do
  match ← ws.send (.text (Frame.encode f).compress) with
  | .ok () => pure ()
  | .error e => throw (IO.userError s!"FAIL: send {e}")

private def recv (ws : LeanWs.Session) : Std.Async.Async Frame := do
  match ← ws.recv with
  | some (.text text) =>
    match Lean.Json.parse text with
    | .ok json =>
      match Frame.decode json with
      | some f => pure f
      | none => throw (IO.userError s!"FAIL: decode {text}")
    | .error e => throw (IO.userError s!"FAIL: json {e}")
  | none => throw (IO.userError "FAIL: socket closed")
  | some (.binary _) => throw (IO.userError "FAIL: unexpected binary")

private def recvClosed (ws : LeanWs.Session) : Std.Async.Async (Option Frame) := do
  match ← ws.recv with
  | none => return none
  | some (.text text) =>
    match Lean.Json.parse text with
    | .ok json => return Frame.decode json
    | .error _ => return none
  | some _ => return none

def run : IO Unit := do
  check "hello codec" (roundTrip (.hello Protocol.v1 "csrf"))
  check "subscribe codec" (roundTrip (.subscribe ⟨1⟩ identity .null none))
  check "event codec" (roundTrip (.event ⟨1⟩ ⟨3⟩ (.str "x")))
  check "topic spaces" (Topic.doc "a" != Topic.user "a")
  let session ← Session.new
  let reg ← Registry.new
  let ctx := TrustedNative.issueContext ⟨"actor", "t", 0⟩ "r"
  session.handle reg [approved true] ctx "csrf" (.subscribe ⟨1⟩ identity .null none)
  let early ← session.take
  check "hello required first" (early.any fun
    | .closed _ .session => true
    | _ => false)
  session.handle reg [approved true] ctx "csrf" (.hello Protocol.v1 "csrf")
  session.handle reg [approved false] ctx "csrf" (.subscribe ⟨1⟩ identity .null none)
  let denied ← session.take
  check "policy denial is fail" (denied.any fun
    | .fail _ _ _ => true
    | _ => false)
  let okSession ← Session.new { maxQueuedEvents := 2048, maxQueuedBytes := 4 * 1024 * 1024, helloTimeoutMs := 0 }
  let reg2 ← Registry.new
  okSession.handle reg2 [approved true] ctx "csrf" (.hello Protocol.v1 "csrf")
  okSession.handle reg2 [approved true] ctx "csrf" (.subscribe ⟨2⟩ identity .null none)
  let ok ← okSession.take
  check "subscribe succeeds" (ok.any fun
    | .subscribed _ _ => true
    | _ => false)
  discard <| okSession.take
  let mut published := 0
  for i in [0:1000] do
    published := published + (← reg2.publish (Topic.doc "1") (.num i))
  check "publish reaches subscriber" (published ≥ 1000)
  let rest ← okSession.take
  let seqs := rest.filterMap fun
    | .event _ seq _ => some seq.n
    | _ => none
  check "1000 publishes arrive with seq 1…1000"
    (seqs == (Array.range 1000 |>.map (· + 1)))
  check "AtLeast admits editor ≥ viewer" (Policy.AtLeast.mk? (ρ := Nat) (min := 1) 3).isSome
  check "AtLeast rejects below min" (Policy.AtLeast.mk? (ρ := Nat) (min := 5) 3).isNone

  let inboundS ← Session.new
  let regI ← Registry.new
  inboundS.handle regI [approved true] ctx "csrf" (.hello Protocol.v1 "csrf")
  inboundS.handle regI [approved true] ctx "csrf" (.subscribe ⟨3⟩ identity .null none)
  discard <| inboundS.take
  inboundS.handle regI [approved true] ctx "csrf" (.send ⟨3⟩ ⟨1⟩ (.str "here"))
  let acked ← inboundS.take
  check "inbound send is ack" (acked.any fun
    | .ack ⟨3⟩ ⟨1⟩ payload => payload == .str "here"
    | _ => false)
  for i in [2:12] do
    inboundS.handle regI [approved true] ctx "csrf" (.send ⟨3⟩ ⟨i⟩ (.str "x"))
  let limited ← inboundS.take
  check "11th send in one second is rate_limited" (limited.any fun
    | .fail ⟨3⟩ _ err => (err.getObjValAs? String "tag").toOption == some "rate_limited"
    | _ => false)

  let ov ← Session.new
  let regO ← Registry.new
  ov.handle regO [approved true] ctx "csrf" (.hello Protocol.v1 "csrf")
  ov.handle regO [approved true] ctx "csrf"
    (.subscribe ⟨1⟩ identity (.mkObj [("k", .str "a")]) none)
  ov.handle regO [approved true] ctx "csrf"
    (.subscribe ⟨2⟩ identity (.mkObj [("k", .str "b")]) none)
  discard <| ov.take
  let chunk := String.ofList (List.replicate (8 * 1024) 'x')
  for _ in [0:80] do
    discard <| regO.publish (Topic.doc "a") (.str chunk)
  let overflowed ← ov.take
  check "byte overflow closes only that subscription" (overflowed.any fun
    | .closed ⟨1⟩ .overflow => true
    | _ => false)
  let n2 ← regO.publish (Topic.doc "b") (.str "still")
  let other ← ov.take
  check "sibling subscription keeps flowing after overflow" (n2 ≥ 1 && other.any fun
    | .event ⟨2⟩ _ payload => payload == .str "still"
    | _ => false)

  Std.Async.Async.block do
    let host ← Host.listenWith (.v4 ⟨.ofParts 127 0 0 1, 0⟩) (← Registry.new) [approved true] ctx "csrf"
      (onCall := some fun _ req =>
        pure (.mkObj [("tag", .str "success"), ("name", .str req.operation.name)]))
    let uri := Std.Http.URI.parse! s!"ws://127.0.0.1:{host.localPort}/"
    match ← LeanWs.Client.connect uri { subprotocols := [protocol] } with
    | .error e => throw (IO.userError s!"FAIL: leanws connect {e}")
    | .ok ws =>
      send ws (.hello Protocol.v1 "csrf")
      send ws (.subscribe ⟨2⟩ identity .null none)
      match ← recv ws with
      | .subscribed _ _ => check "leanws subscribe succeeds" true
      | f => throw (IO.userError s!"FAIL: expected subscribed, got {(Frame.encode f).compress}")
      let n ← host.registry.publish (Topic.doc "1") (.str "tick")
      check "leanws publish reaches socket" (n ≥ 1)
      match ← recv ws with
      | .event _ seq payload =>
        check "leanws event delivered" (payload == .str "tick")
        check "leanws event seq starts at 1" (seq.n == 1)
      | f => throw (IO.userError s!"FAIL: expected event, got {(Frame.encode f).compress}")
      send ws (.send ⟨2⟩ ⟨9⟩ (.str "pong"))
      match ← recv ws with
      | .ack ⟨2⟩ ⟨9⟩ payload => check "leanws inbound ack" (payload == .str "pong")
      | f => throw (IO.userError s!"FAIL: expected ack, got {(Frame.encode f).compress}")
      send ws (.call ⟨4⟩ ⟨saveId, .command, .null⟩)
      match ← recv ws with
      | .reply ⟨4⟩ json =>
        check "call replies" ((json.getObjValAs? String "name").toOption == some "save")
      | f => throw (IO.userError s!"FAIL: expected reply, got {(Frame.encode f).compress}")
      ws.close
      host.drain

  IO.FS.withTempDir fun dir => do
    let inst := LeanDb.Instance.ofPath (dir / "auth.sqlite")
    let .ok runtime ← LeanAppNative.Runtime.Service.new Demo.base inst
      | throw (IO.userError "FAIL: auth session")
    let .ok auth ← Service.new runtime
      | throw (IO.userError "FAIL: auth service")
    try
      let alice ← match ← auth.signup "alice_ws" password with
        | .ok v => pure v | .error e => throw (IO.userError s!"FAIL: signup alice {repr e}")
      let bob ← match ← auth.signup "bob_ws" password with
        | .ok v => pure v | .error e => throw (IO.userError s!"FAIL: signup bob {repr e}")
      let seen ← IO.mkRef (#[])
      let ch := approved true seen
      Std.Async.Async.block do
        let host ← Host.listen (.v4 ⟨.ofParts 127 0 0 1, 0⟩) (← Registry.new) [ch] auth
          (fun o => o == originOk)
        let uri := Std.Http.URI.parse! s!"ws://127.0.0.1:{host.localPort}/"
        match ← LeanWs.Client.connect uri { subprotocols := [protocol], headers := wsHeaders none } with
        | .error (.rejected (.status 401)) => check "missing cookie is 401 at upgrade" true
        | other => throw (IO.userError s!"FAIL: expected 401, got {repr (other.map fun _ => ())}")
        match ← LeanWs.Client.connect uri
            { subprotocols := [protocol], headers := wsHeaders (some alice.token) "https://evil.example" } with
        | .error (.rejected (.status 403)) => check "forged Origin is 403" true
        | other => throw (IO.userError s!"FAIL: expected 403, got {repr (other.map fun _ => ())}")
        match ← LeanWs.Client.connect uri
            { subprotocols := [protocol], headers := wsHeaders (some alice.token) } with
        | .error e => throw (IO.userError s!"FAIL: alice connect {e}")
        | .ok ws =>
          send ws (.hello Protocol.v1 "not-the-csrf")
          let closed ← ws.waitClosed
          check "wrong CSRF in hello is 1008" (closed.code == .policyViolation)
        match ← LeanWs.Client.connect uri
            { subprotocols := [protocol], headers := wsHeaders (some alice.token) } with
        | .error e => throw (IO.userError s!"FAIL: alice reconnect {e}")
        | .ok wsA =>
          match ← LeanWs.Client.connect uri
              { subprotocols := [protocol], headers := wsHeaders (some bob.token) } with
          | .error e => throw (IO.userError s!"FAIL: bob connect {e}")
          | .ok wsB =>
            send wsA (.hello Protocol.v1 alice.csrf)
            send wsA (.subscribe ⟨1⟩ identity .null none)
            send wsB (.hello Protocol.v1 bob.csrf)
            send wsB (.subscribe ⟨1⟩ identity .null none)
            match ← recv wsA with
            | .subscribed _ _ => pure ()
            | f => throw (IO.userError s!"FAIL: alice subscribed { (Frame.encode f).compress }")
            match ← recv wsB with
            | .subscribed _ _ => pure ()
            | f => throw (IO.userError s!"FAIL: bob subscribed { (Frame.encode f).compress }")
            let actors ← seen.get
            check "two sockets resolve two RequestContexts"
              (actors.any (· == alice.user.actor) && actors.any (· == bob.user.actor) &&
                alice.user.actor != bob.user.actor)
            let before ← auth.queue
            send wsA (.send ⟨1⟩ ⟨1⟩ (.str "presence"))
            match ← recv wsA with
            | .ack _ _ _ => check "presence inbound acks" true
            | f => throw (IO.userError s!"FAIL: expected ack, got {(Frame.encode f).compress}")
            let after ← auth.queue
            check "inbound does not enter withConnection" (after.completed == before.completed)
            match ← auth.logout alice.token alice.csrf with
            | .ok () => pure ()
            | .error e => throw (IO.userError s!"FAIL: logout {repr e}")
            let mut gotSession := false
            for _ in [0:20] do
              match ← recvClosed wsA with
              | some (.closed _ .session) => gotSession := true; break
              | none => gotSession := true; break
              | some _ => pure ()
            check "logout while connected closes session" gotSession
            wsB.close
            host.drain
    finally runtime.close

  IO.println "PASS channel protocol qualification (leanws loopback)"

end ChannelFixture

def main : IO Unit := ChannelFixture.run
