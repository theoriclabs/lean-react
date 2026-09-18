import LeanApp.Channel
import LeanContract.Channel
import Std.Data.HashMap
import Std.Sync.Mutex

namespace LeanAppNative.Channels
open LeanApp Contract

/-- Per-socket caps. Overflow of events or bytes closes that **subscription**,
    never the socket (LA-14 / LA-17). -/
structure SessionLimits where
  maxSubscriptions : Nat := 32
  maxQueuedEvents : Nat := 512
  maxQueuedBytes : Nat := 512 * 1024
  inboundPerSecond : Nat := 10
  helloTimeoutMs : Nat := 5000
  deriving Repr

structure Subscriber where
  sub : SubId
  principal : Option Principal
  seq : IO.Ref EventSeq
  enqueue : Frame → IO Bool
  alive : IO.Ref Bool

structure Registry where
  private topics : IO.Ref (Std.HashMap Topic (Array Subscriber))
  private bySub : IO.Ref (Std.HashMap (String × Nat) (Array Topic))
  private publishLock : Std.Mutex Unit
  published : IO.Ref Nat
  revoked : IO.Ref Nat

def Registry.new : IO Registry :=
  return ⟨← IO.mkRef {}, ← IO.mkRef {}, ← Std.Mutex.new (), ← IO.mkRef 0, ← IO.mkRef 0⟩

private def subKey (actor : String) (sub : SubId) : String × Nat := (actor, sub.n)

def Registry.subscribe (r : Registry) (actor : String) (topics : List Topic) (sub : Subscriber) :
    IO Unit := do
  r.bySub.modify (·.insert (subKey actor sub.sub) topics.toArray)
  for t in topics do
    r.topics.modify fun m =>
      m.insert t ((m.getD t #[]).push sub)

def Registry.unsubscribe (r : Registry) (actor : String) (sub : SubId) : IO Unit := do
  let key := subKey actor sub
  let topics := (← r.bySub.get).getD key #[]
  r.bySub.modify (·.erase key)
  for t in topics do
    r.topics.modify fun m =>
      m.insert t ((m.getD t #[]).filter (fun s => !(s.sub == sub && (s.principal.map (·.actor)).getD actor == actor)))

/-- Enqueue `event` on every live subscriber of `topic`. `seq` is stamped under
    the registry publish lock so concurrent publishes stay gap-free. -/
def Registry.publish (r : Registry) (topic : Topic) (payload : Lean.Json) : IO Nat :=
  r.publishLock.atomically fun _ => do
    r.published.modify (· + 1)
    let subs := (← r.topics.get).getD topic #[]
    let mut n := 0
    for s in subs do
      if ← s.alive.get then
        let next := EventSeq.succ (← s.seq.get)
        s.seq.set next
        let accepted ← s.enqueue (.event s.sub next payload)
        if accepted then n := n + 1
    return n

/-- Close matching subscriptions with `revoked` and drop them. -/
def Registry.revoke (r : Registry) (topic : Topic) (keep : Principal → Bool) : IO Nat := do
  let subs := (← r.topics.get).getD topic #[]
  let mut n := 0
  for s in subs do
    let drop := match s.principal with
      | none => true
      | some p => !keep p
    if drop then
      if ← s.alive.get then
        discard <| s.enqueue (.closed s.sub .revoked)
        s.alive.set false
        n := n + 1
      if let some p := s.principal then
        Registry.unsubscribe r p.actor s.sub
  r.revoked.modify (· + n)
  return n

def Registry.closeAll (r : Registry) (reason : CloseReason) : IO Unit := do
  let m ← r.topics.get
  for (_, subs) in m.toList do
    for s in subs do
      if ← s.alive.get then
        discard <| s.enqueue (.closed s.sub reason)
        s.alive.set false
  r.topics.set {}
  r.bySub.set {}

/-- How `Session.drive` asks the host to treat the socket. -/
inductive Drive where
  | cont
  | stop
  | policy

structure LiveSub where
  channel : ApprovedChannel IO
  params : Lean.Json
  topics : List Topic
  queuedEvents : IO.Ref Nat
  queuedBytes : IO.Ref Nat
  alive : IO.Ref Bool

/-- In-memory protocol machine for tests (no sockets). -/
structure Session where
  helloed : IO.Ref Bool
  principal : IO.Ref (Option Principal)
  outbound : IO.Ref (Array Frame)
  subscriptions : IO.Ref Nat
  live : IO.Ref (Std.HashMap Nat LiveSub)
  inboundAt : IO.Ref Nat
  inboundN : IO.Ref Nat
  /-- When true (the default in-memory sink), queued bytes stay until `take`.
      A live socket clears the count after a successful send. -/
  buffering : IO.Ref Bool
  limits : SessionLimits
  private sink : IO.Ref (Frame → IO Bool)

def Session.new (limits : SessionLimits := {}) : IO Session := do
  let outbound ← IO.mkRef (#[])
  let sink ← IO.mkRef fun (f : Frame) => do
    outbound.modify (·.push f)
    return true
  return {
    helloed := ← IO.mkRef false
    principal := ← IO.mkRef none
    outbound
    subscriptions := ← IO.mkRef 0
    live := ← IO.mkRef {}
    inboundAt := ← IO.mkRef 0
    inboundN := ← IO.mkRef 0
    buffering := ← IO.mkRef true
    limits
    sink
  }

/-- Replace the default in-memory queue (used by a live leanws session). -/
def Session.attach (s : Session) (send : Frame → IO Bool) : IO Unit := do
  s.buffering.set false
  s.sink.set send

def Session.push (s : Session) (f : Frame) : IO Bool := do
  (← s.sink.get) f

def Session.take (s : Session) : IO (Array Frame) := do
  let q ← s.outbound.modifyGet fun q => (q, #[])
  let m ← s.live.get
  for (_, live) in m.toList do
    live.queuedEvents.set 0
    live.queuedBytes.set 0
  return q

def Session.topics (s : Session) : IO (List (Topic × SubId)) := do
  let m ← s.live.get
  let mut out : List (Topic × SubId) := []
  for (n, live) in m.toList do
    for t in live.topics do
      out := (t, ⟨n⟩) :: out
  return out

private def failPayload (tag : String) : Lean.Json :=
  .mkObj [("tag", .str tag)]

private def callFail : CallError Lean.Json → Lean.Json
  | .domain j => j
  | .unauthenticated => failPayload "unauthenticated"
  | .forbidden => failPayload "forbidden"
  | .decode _ => failPayload "decode"
  | .protocol e => failPayload e.code
  | .transport e => failPayload e.code
  | .incompatible _ => failPayload "incompatible"
  | .cancelled => failPayload "cancelled"

private def frameBytes (f : Frame) : Nat :=
  (Frame.encode f).compress.utf8ByteSize

private def Session.admitInbound (s : Session) : IO Bool := do
  let now ← IO.monoMsNow
  let window ← s.inboundAt.get
  if now - window ≥ 1000 || window == 0 then
    s.inboundAt.set now
    s.inboundN.set 1
    return true
  let n ← s.inboundN.get
  if n ≥ s.limits.inboundPerSecond then return false
  s.inboundN.set (n + 1)
  return true

private def Session.enqueueFor (s : Session) (reg : Registry) (actor : String)
    (sub : SubId) (live : LiveSub) (f : Frame) : IO Bool := do
  unless ← live.alive.get do return false
  let bytes := frameBytes f
  let ev ← live.queuedEvents.get
  let bq ← live.queuedBytes.get
  let overflow := ev ≥ s.limits.maxQueuedEvents || bq + bytes > s.limits.maxQueuedBytes
  if overflow then
    live.alive.set false
    Registry.unsubscribe reg actor sub
    s.live.modify (·.erase sub.n)
    s.subscriptions.modify fun n => n - 1
    discard <| s.push (.closed sub .overflow)
    return false
  let buffering ← s.buffering.get
  if buffering then
    live.queuedEvents.set (ev + 1)
    live.queuedBytes.set (bq + bytes)
    s.push f
  else
    let ok ← s.push f
    if ok then return true
    live.queuedEvents.set (ev + 1)
    live.queuedBytes.set (bq + bytes)
    let ev' ← live.queuedEvents.get
    let bq' ← live.queuedBytes.get
    if ev' ≥ s.limits.maxQueuedEvents || bq' > s.limits.maxQueuedBytes then
      live.alive.set false
      Registry.unsubscribe reg actor sub
      s.live.modify (·.erase sub.n)
      s.subscriptions.modify fun n => n - 1
      discard <| s.push (.closed sub .overflow)
      return false
    return false

/-- Drive one inbound frame. `expectedCsrf` is the session CSRF after upgrade. -/
def Session.drive (s : Session) (reg : Registry) (channels : List (ApprovedChannel IO))
    (context : RequestContext) (expectedCsrf : String) (frame : Frame)
    (onCall : Option (RequestContext → WireRequest → IO Lean.Json) := none) : IO Drive := do
  let actor := (context.principal.map (·.actor)).getD ""
  match frame with
  | .hello p csrf =>
    if p != Protocol.v1 || csrf != expectedCsrf then
      return .policy
    s.helloed.set true
    s.principal.set context.principal
    return .cont
  | _ =>
    unless ← s.helloed.get do
      discard <| s.push (.closed ⟨0⟩ .session)
      return .stop
    match frame with
    | .subscribe sub identity params _resume =>
      let n ← s.subscriptions.get
      if n ≥ s.limits.maxSubscriptions then
        discard <| s.push (.closed sub .overflow)
        return .cont
      match channels.find? (·.identity == identity) with
      | none =>
        discard <| s.push (.fail sub none (failPayload "not_found"))
        return .cont
      | some ch =>
        match ← ch.subscribe context params with
        | .error (.forbidden) =>
          discard <| s.push (.fail sub none (failPayload "forbidden")); return .cont
        | .error (.unauthenticated) =>
          discard <| s.push (.fail sub none (failPayload "unauthenticated")); return .cont
        | .error e =>
          discard <| s.push (.fail sub none (callFail e)); return .cont
        | .ok (topics, snap) =>
          s.subscriptions.modify (· + 1)
          let alive ← IO.mkRef true
          let queuedEvents ← IO.mkRef (0 : Nat)
          let queuedBytes ← IO.mkRef (0 : Nat)
          let seq ← IO.mkRef EventSeq.zero
          let live : LiveSub := { channel := ch, params, topics, queuedEvents, queuedBytes, alive }
          s.live.modify (·.insert sub.n live)
          let subr : Subscriber := {
            sub, principal := context.principal, seq, alive
            enqueue := fun f => s.enqueueFor reg actor sub live f
          }
          reg.subscribe actor topics subr
          discard <| s.push (.subscribed sub snap)
          return .cont
    | .unsubscribe sub =>
      reg.unsubscribe actor sub
      if let some live := (← s.live.get).get? sub.n then
        live.alive.set false
      s.live.modify (·.erase sub.n)
      return .cont
    | .send sub msg payload =>
      match (← s.live.get).get? sub.n with
      | none =>
        discard <| s.push (.fail sub (some msg) (failPayload "not_found")); return .cont
      | some live =>
        unless ← s.admitInbound do
          discard <| s.push (.fail sub (some msg) (failPayload "rate_limited"))
          return .cont
        match ← live.channel.inbound context live.params payload with
        | .ok ack => discard <| s.push (.ack sub msg ack)
        | .error e => discard <| s.push (.fail sub (some msg) (callFail e))
        return .cont
    | .call msg request =>
      match onCall with
      | none => return .cont
      | some dispatch =>
        let json ← dispatch context request
        discard <| s.push (.reply msg json)
        return .cont
    | _ => return .cont

/-- Drive one inbound frame, ignoring the host-level outcome. -/
def Session.handle (s : Session) (reg : Registry) (channels : List (ApprovedChannel IO))
    (context : RequestContext) (expectedCsrf : String) (frame : Frame) : IO Unit := do
  discard <| s.drive reg channels context expectedCsrf frame

end LeanAppNative.Channels
