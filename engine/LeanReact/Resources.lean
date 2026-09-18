import LeanReact.Core
import LeanContract.CallFailure

namespace LeanReact

structure ResourceToken where
  key : Key
  generation : Nat
  deriving Repr, BEq, DecidableEq

/-- Domain failures stay typed. Unexpected host exceptions have a separate representation, and transport
failures the host bridge recognises (the JS `CallFailure` class) arrive as `.call`. -/
inductive ResourceFailure (Error : Type) where
  | loader (error : Error)
  | exception (message : String)
  | call (failure : Contract.CallFailure)
  deriving Repr, BEq

/-- Collapses a failure into the loader's typed error or a `CallFailure`. This helper was chosen over
routing transport failures into the loader error type: loaders keep returning plain `Except Error Value`,
existing `.loader` matches stay valid, and a component decides once how to show each transport case. An
unrecognised host exception is reported as `.transport message`, since the call did not complete. -/
def Resource.failureAs : ResourceFailure Error → Except Contract.CallFailure Error
  | .loader error => .ok error
  | .call failure => .error failure
  | .exception message => .error (.transport message)

inductive ResourceState (Value Error : Type) where
  | idle
  | loading (token : ResourceToken)
  | success (token : ResourceToken) (value : Value)
  | failure (token : ResourceToken) (error : ResourceFailure Error)
  deriving Repr, BEq

/-- A pure reference state machine for request ordering; it performs no scheduling. -/
structure ResourceTracker (Value Error : Type) where
  generation : Nat := 0
  state : ResourceState Value Error := .idle
  deriving Repr, BEq

namespace ResourceTracker

def begin (tracker : ResourceTracker Value Error) (key : Key) : ResourceToken × ResourceTracker Value Error :=
  let token := { key, generation := tracker.generation + 1 }
  (token, { generation := token.generation, state := .loading token })

/-- Only the currently loading generation may settle, and it can settle only once. -/
def settle (tracker : ResourceTracker Value Error) (token : ResourceToken)
    (result : Except (ResourceFailure Error) Value) : ResourceTracker Value Error :=
  match tracker.state with
  | .loading current =>
    if current == token then
      { tracker with state := match result with | .ok value => .success token value | .error error => .failure token error }
    else tracker
  | _ => tracker

def cancel (tracker : ResourceTracker Value Error) : ResourceTracker Value Error :=
  { tracker with state := .idle }

end ResourceTracker

structure ResourceRequest where
  token : ResourceToken
  cancelled : Action Bool
  /-- Register cleanup for replacement/unmount; a late registration runs immediately. -/
  onCleanup : Action Unit → Action Unit

structure Resource (Value Error : Type) where
  state : ResourceState Value Error
  refresh : Action Unit
  /-- Current controller state at action time. This does not request a React render flush. -/
  read : Action (ResourceState Value Error)

private def releaseResourceCleanups (pending : IO.Ref (Array (Action Unit))) : IO Unit := do
  let cleanups ← pending.get
  pending.set #[]
  let mut firstError : Option IO.Error := none
  for cleanup in cleanups.reverse do
    try cleanup.runIO catch error =>
      if firstError.isNone then firstError := some error
  if let some error := firstError then throw error

/-- Native reference: one controller per invocation, explicit commit/refresh, sequential IO.
The browser intrinsic owns async scheduling, committed dependencies, and mounted identities. -/
def useResource {Value Error : Type} (key : Key)
    (loader : ResourceRequest → Action (Except Error Value))
    (dependencies : Array Dependency := #[]) (enabled : Bool := true)
    (site : String := "") : Hook (Resource Value Error) := ⟨fun env => do
  (Hook.mark "resource" site).runRender env
  let _ := dependencies
  let tracker ← IO.mkRef ({} : ResourceTracker Value Error)
  let mounted ← IO.mkRef false
  let disposeCurrent ← IO.mkRef (Action.pure ())
  let refresh : Action Unit := ⟨do
    if !(← mounted.get) || !enabled then return
    let previousGeneration := (← tracker.get).generation
    (← disposeCurrent.get).runIO
    if !(← mounted.get) || (← tracker.get).generation != previousGeneration then return
    let (token, next) := (← tracker.get).begin key
    tracker.set next
    let cancelled ← IO.mkRef false
    let cleanups ← IO.mkRef (#[] : Array (Action Unit))
    let dispose : Action Unit := ⟨do
      if ← cancelled.get then return
      cancelled.set true
      tracker.modify fun current => if current.generation == token.generation then current.cancel else current
      releaseResourceCleanups cleanups⟩
    disposeCurrent.set dispose
    let request : ResourceRequest := {
      token
      cancelled := ⟨cancelled.get⟩
      onCleanup := fun cleanup => ⟨do
        if ← cancelled.get then cleanup.runIO else cleanups.modify (·.push cleanup)⟩
    }
    let result ← try
      pure <| (← (loader request).runIO).mapError ResourceFailure.loader
    catch error => pure <| .error (.exception error.toString)
    tracker.modify (fun current => current.settle token result)⟩
  let setup : Action (Action Unit) := ⟨do
    mounted.set true
    try
      refresh.runIO
      pure ⟨do mounted.set false; (← disposeCurrent.get).runIO⟩
    catch error =>
      mounted.set false
      try (← disposeCurrent.get).runIO catch _ => pure ()
      throw error⟩
  env.effects.modify (·.push setup)
  pure {
    state := .idle
    refresh
    read := ⟨return (← tracker.get).state⟩
  }⟩

end LeanReact
