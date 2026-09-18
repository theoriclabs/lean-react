import LeanReact.Core
import LeanContract.Channel

namespace LeanReact
open Contract

inductive ChannelState where
  | connecting
  | subscribing
  | live (seq : EventSeq)
  | resubscribing (reason : CloseReason)
  | offline (attempt : Nat)
  | denied (error : Lean.Json)
  deriving BEq

structure ChannelHandle (Inbound Ack Error : Type) where
  state : ChannelState
  send : Inbound → Action (Except Error Ack)
  resubscribe : Action Unit

/-- Pure tracker for tests and the native reference. -/
structure ChannelTracker where
  generation : Nat := 0
  state : ChannelState := .connecting
  lastSeq : Option EventSeq := none
  deriving BEq

namespace ChannelTracker

def subscribe (t : ChannelTracker) : ChannelTracker :=
  { t with generation := t.generation + 1, state := .subscribing, lastSeq := none }

def live (t : ChannelTracker) : ChannelTracker :=
  { t with state := .live .zero }

def event (t : ChannelTracker) (seq : EventSeq) : Option ChannelTracker :=
  match t.state, t.lastSeq with
  | .live _, none => some { t with lastSeq := some seq, state := .live seq }
  | .live _, some prev =>
    if seq.n == prev.n + 1 then some { t with lastSeq := some seq, state := .live seq }
    else some { t with state := .resubscribing .overflow }
  | _, _ => none

def deny (t : ChannelTracker) (error : Lean.Json) : ChannelTracker :=
  { t with state := .denied error }

def offline (t : ChannelTracker) (attempt : Nat) : ChannelTracker :=
  { t with state := .offline attempt }

end ChannelTracker

/-- Native reference. The browser intrinsic owns the multiplexed socket. -/
def useChannel [Inhabited Err] {P E I A S : Type} (ch : Channel P E I A Err S)
    (params : P) (resume : Option P)
    (onEvent : EventSeq → E → Action Unit) (onSnapshot : S → Action Unit)
    (dependencies : Array Dependency) (enabled : Bool) (site : String) :
    Hook (ChannelHandle I A Err) := ⟨fun env => do
  (Hook.mark "channel" site).runRender env
  let _ := (ch, params, resume, onEvent, onSnapshot, dependencies)
  let state : ChannelState := if enabled then .live .zero else .offline 0
  return {
    state
    send := fun _ => Action.pure (.error default)
    resubscribe := Action.pure ()
  }⟩

end LeanReact
