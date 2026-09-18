import LeanAppNative.Channels
import LeanAppNative.ChannelHost
import LeanApp.Channel
import LeanApp.Policy
import LeanWs

open LeanApp Contract
open LeanAppNative.Channels

namespace ChannelFixture

def identity : OperationId := ⟨"tickets", "watch", "1"⟩

def approved (allow : Bool) : ApprovedChannel IO := {
  identity
  published := {}
  subscribe := fun ctx _ => do
    if ctx.principal.isNone then return .error .unauthenticated
    if !allow then return .error .forbidden
    return .ok ([Topic.doc "1"], some (.mkObj [("ok", .bool true)]))
  inbound := fun _ _ _ => pure (.ok .null)
}

def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

def roundTrip (f : Frame) : Bool :=
  (Frame.decode (Frame.encode f)).map Frame.encode == some (Frame.encode f)

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
  let okSession ← Session.new
  let reg2 ← Registry.new
  okSession.handle reg2 [approved true] ctx "csrf" (.hello Protocol.v1 "csrf")
  okSession.handle reg2 [approved true] ctx "csrf" (.subscribe ⟨2⟩ identity .null none)
  let ok ← okSession.take
  check "subscribe succeeds" (ok.any fun
    | .subscribed _ _ => true
    | _ => false)
  let n ← reg2.publish (Topic.doc "1") (.str "tick")
  check "publish reaches subscriber" (n ≥ 1)
  check "AtLeast admits editor ≥ viewer" (Policy.AtLeast.mk? (ρ := Nat) (min := 1) 3).isSome
  check "AtLeast rejects below min" (Policy.AtLeast.mk? (ρ := Nat) (min := 5) 3).isNone
  Std.Async.Async.block do
    let host ← Host.listen (.v4 ⟨.ofParts 127 0 0 1, 0⟩) (← Registry.new) [approved true] ctx "csrf"
    let uri := Std.Http.URI.parse! s!"ws://127.0.0.1:{host.localPort}/"
    match ← LeanWs.Client.connect uri { subprotocols := [protocol] } with
    | .error e => throw (IO.userError s!"FAIL: leanws connect {e}")
    | .ok ws =>
      let send (f : Frame) : Std.Async.Async Unit := do
        match ← ws.send (.text (Frame.encode f).compress) with
        | .ok () => pure ()
        | .error e => throw (IO.userError s!"FAIL: send {e}")
      let recv : Std.Async.Async Frame := do
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
      send (.hello Protocol.v1 "csrf")
      send (.subscribe ⟨2⟩ identity .null none)
      match ← recv with
      | .subscribed _ _ => check "leanws subscribe succeeds" true
      | f => throw (IO.userError s!"FAIL: expected subscribed, got {(Frame.encode f).compress}")
      let n ← host.registry.publish (Topic.doc "1") (.str "tick")
      check "leanws publish reaches socket" (n ≥ 1)
      match ← recv with
      | .event _ _ payload => check "leanws event delivered" (payload == .str "tick")
      | f => throw (IO.userError s!"FAIL: expected event, got {(Frame.encode f).compress}")
      ws.close
      host.drain
  IO.println "PASS channel protocol qualification (leanws loopback)"

end ChannelFixture

def main : IO Unit := ChannelFixture.run
