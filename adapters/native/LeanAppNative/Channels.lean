import LeanApp.Channel
import LeanContract.Channel
import Std.Data.HashMap

namespace LeanAppNative.Channels
open LeanApp Contract

structure Subscriber where
  sub : SubId
  principal : Option Principal
  enqueue : Frame → IO Bool
  alive : IO.Ref Bool

structure Registry where
  private topics : IO.Ref (Std.HashMap Topic (Array Subscriber))
  private bySub : IO.Ref (Std.HashMap (String × Nat) (Array Topic))
  published : IO.Ref Nat
  revoked : IO.Ref Nat

def Registry.new : IO Registry :=
  return ⟨← IO.mkRef {}, ← IO.mkRef {}, ← IO.mkRef 0, ← IO.mkRef 0⟩

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

/-- Enqueue `event` on every live subscriber of `topic`. Returns how many accepted it. -/
def Registry.publish (r : Registry) (topic : Topic) (payload : Lean.Json) : IO Nat := do
  r.published.modify (· + 1)
  let subs := (← r.topics.get).getD topic #[]
  let mut n := 0
  for s in subs do
    if ← s.alive.get then
      let accepted ← s.enqueue (.event s.sub ⟨0⟩ payload)
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

/-- In-memory protocol machine for tests (no sockets). -/
structure Session where
  helloed : IO.Ref Bool
  principal : IO.Ref (Option Principal)
  outbound : IO.Ref (Array Frame)
  subscriptions : IO.Ref Nat
  maxSubscriptions : Nat := 32
  maxQueued : Nat := 512
  private sink : IO.Ref (Frame → IO Bool)

def Session.new : IO Session := do
  let outbound ← IO.mkRef (#[])
  let maxQueued := 512
  let sink ← IO.mkRef fun (f : Frame) => do
    let q ← outbound.get
    if q.size ≥ maxQueued then return false
    outbound.modify (·.push f)
    return true
  return {
    helloed := ← IO.mkRef false
    principal := ← IO.mkRef none
    outbound, subscriptions := ← IO.mkRef 0
    maxSubscriptions := 32, maxQueued, sink
  }

/-- Replace the default in-memory queue (used by a live leanws session). -/
def Session.attach (s : Session) (send : Frame → IO Bool) : IO Unit :=
  s.sink.set send

def Session.push (s : Session) (f : Frame) : IO Bool := do
  (← s.sink.get) f

def Session.take (s : Session) : IO (Array Frame) := s.outbound.modifyGet fun q => (q, #[])

/-- Drive one inbound frame. `authed` is the principal after a valid `hello`. -/
def Session.handle (s : Session) (reg : Registry) (channels : List (ApprovedChannel IO))
    (context : RequestContext) (expectedCsrf : String) (frame : Frame) : IO Unit := do
  match frame with
  | .hello p csrf =>
    if p != Protocol.v1 || csrf != expectedCsrf then
      discard <| s.push (.closed ⟨0⟩ .session)
      return
    s.helloed.set true
    s.principal.set context.principal
  | _ =>
    unless ← s.helloed.get do
      discard <| s.push (.closed ⟨0⟩ .session)
      return
    match frame with
    | .subscribe sub identity params _resume =>
      let n ← s.subscriptions.get
      if n ≥ s.maxSubscriptions then
        discard <| s.push (.closed sub .overflow)
        return
      match channels.find? (·.identity == identity) with
      | none => discard <| s.push (.fail sub none (.mkObj [("tag", .str "not_found")]))
      | some ch =>
        match ← ch.subscribe context params with
        | .error (.forbidden) => discard <| s.push (.fail sub none (.mkObj [("tag", .str "forbidden")]))
        | .error (.unauthenticated) => discard <| s.push (.fail sub none (.mkObj [("tag", .str "unauthenticated")]))
        | .error _ => discard <| s.push (.fail sub none (.mkObj [("tag", .str "error")]))
        | .ok (topics, snap) =>
          s.subscriptions.modify (· + 1)
          let alive ← IO.mkRef true
          let queued ← IO.mkRef (0 : Nat)
          let subr : Subscriber := {
            sub, principal := context.principal, alive
            enqueue := fun f => do
              let n ← queued.get
              if n ≥ s.maxQueued then
                discard <| s.push (.closed sub .overflow)
                alive.set false
                return false
              queued.modify (· + 1)
              s.push f
          }
          reg.subscribe ((context.principal.map (·.actor)).getD "") topics subr
          discard <| s.push (.subscribed sub snap)
    | .unsubscribe sub =>
      reg.unsubscribe ((context.principal.map (·.actor)).getD "") sub
    | .send sub _msg _payload =>
      discard <| s.push (.fail sub (some ⟨0⟩) (.mkObj [("tag", .str "no_inbound")]))
    | _ => pure ()

end LeanAppNative.Channels
