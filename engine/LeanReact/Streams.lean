import LeanReact.Core

namespace LeanReact

inductive StreamCloseReason where
  | user | error (message : String) | exhausted
  deriving Repr, BEq

inductive StreamState where
  | connecting (attempt : Nat)
  | open
  | reconnecting (attempt : Nat) (lastError : String)
  | closed (reason : StreamCloseReason)
  deriving Repr, BEq

structure StreamEvent (ε : Type) where
  id : Option String
  event : ε
  deriving Repr, BEq

structure Stream (ε : Type) where
  state : StreamState
  reconnect : Action Unit
  close : Action Unit

structure StreamTracker (ε : Type) where
  generation : Nat := 0
  state : StreamState := .connecting 0
  deriving Repr, BEq

namespace StreamTracker

def becomeOpen (t : StreamTracker ε) : StreamTracker ε :=
  { t with generation := t.generation + 1, state := .open }

def deliver (t : StreamTracker ε) (_ : StreamEvent ε) : StreamTracker ε := t

def drop (t : StreamTracker ε) : StreamTracker ε := t

def reconnect (t : StreamTracker ε) (attempt : Nat) (err : String) : StreamTracker ε :=
  { t with state := .reconnecting attempt err }

end StreamTracker

structure StreamRequest where
  key : Key
  lastEventId : Option String := none

structure StreamConnection where
  close : Action Unit

def useStream {ε : Type} (key : Key)
    (connect : StreamRequest → Action StreamConnection)
    (decode : Lean.Json → Except String ε)
    (onEvent : StreamEvent ε → Action Unit)
    (dependencies : Array Dependency) (enabled : Bool) (site : String) :
    Hook (Stream ε) := ⟨fun env => do
  (Hook.mark "stream" site).runRender env
  let _ := (key, connect, decode, onEvent, dependencies)
  return {
    state := if enabled then StreamState.open else .closed .user
    reconnect := Action.pure ()
    close := Action.pure ()
  }⟩

end LeanReact
