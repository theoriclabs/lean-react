import LeanReact.Core

/-! # Host capabilities behind commands and subscriptions

Each is a browser intrinsic (`engine/adapters/leanjs-react.mjs`); the Lean bodies are the
native reference. Natively, timers and key listeners never fire, storage is an in-memory map,
and `now` is a monotonic clock rather than wall time. -/

namespace LeanReact.Program.Effects

/-- Resolve after `ms` milliseconds (browser: `setTimeout`). -/
def sleep (ms : Nat) : Action Unit := ⟨IO.sleep ms.toUInt32⟩

/-- Milliseconds since the epoch (browser: `Date.now()`). -/
def nowMs : Action Nat := ⟨IO.monoMsNow⟩

/-- A random number below `bound` (0 when `bound` is 0). Browser: `crypto.getRandomValues`. -/
def randomBelow (bound : Nat) : Action Nat := ⟨if bound == 0 then pure 0 else IO.rand 0 (bound - 1)⟩

initialize storageRef : IO.Ref (List (String × String)) ← IO.mkRef []

/-- `localStorage.getItem`. -/
def storageGet (key : String) : Action (Option String) := ⟨return (← storageRef.get).lookup key⟩

/-- `localStorage.setItem`. -/
def storageSet (key value : String) : Action Unit :=
  ⟨storageRef.modify fun entries => (key, value) :: entries.filter (·.1 != key)⟩

/-- Focus the element with this `id`, if any. -/
def focusById (_id : String) : Action Unit := pure ()

/-- Go to `path` through the router's history (push, or replace). -/
def navigateTo (_path : String) (_replace : Bool) : Action Unit := pure ()

/-- Run `tick` every `ms` milliseconds until the returned action stops it. -/
def every (_ms : Nat) (_tick : Action Unit) : Action (Action Unit) := pure (pure ())

/-- Run `handler` for every document-level key press until the returned action stops it. -/
def onDocumentKeyDown (_handler : KeyEvent → Action Unit) : Action (Action Unit) := pure (pure ())

/-- Start `work` without waiting for it (an asynchronous command must not hold up the next). -/
def spawn (work : Action Unit) : Action Unit := work

end LeanReact.Program.Effects
