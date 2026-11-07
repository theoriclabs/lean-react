import LeanReact.Core
import LeanReact.Program.Effects
import LeanJS.StackSafe

/-! # Commands and subscriptions as data -/

namespace LeanReact.Program

/-- What `update` asks the host to do after a transition. The host runs commands after the
model is committed, in order; a command's result comes back as a message. -/
inductive Cmd (Msg : Type) where
  | none
  | batch (commands : List (Cmd Msg))
  /-- Host work whose result, if any, is the next message (see `Cmd.perform`). -/
  | task (work : Action (Option Msg))

@[leanjs_stack_safe] def Cmd.map (f : α → β) : Cmd α → Cmd β
  | .none => .none
  | .batch commands => .batch (commands.map (Cmd.map f))
  | .task work => .task (work.map (Option.map f))

/-- Run an `Action` (a service call, a host capability) and send its result as a message:
the bridge from `update` to existing `Action`-based services. A host exception arrives as
`.error` instead of escaping. -/
def Cmd.perform (work : Action α) (toMsg : Except IO.Error α → Msg) : Cmd Msg :=
  .task (Action.catchError (work.map fun value => some (toMsg (.ok value))) fun error => pure (some (toMsg (.error error))))

/-- Run an `Action` for its effect only. -/
def Cmd.exec (work : Action Unit) : Cmd Msg := .task (work.map fun _ => Option.none)

namespace Cmd
open Effects

/-- Send `msg` after `ms` milliseconds. -/
def after (ms : Nat) (msg : Msg) : Cmd Msg := .task (do sleep ms; pure (some msg))
/-- Go to `path` (through the router's history, so `useLocation`/`routerProvider` see it). -/
def navigate (path : String) : Cmd Msg := .exec (navigateTo path false)
/-- Replace the current URL without a new history entry. -/
def replaceUrl (path : String) : Cmd Msg := .exec (navigateTo path true)
/-- Move focus to the element with this `id`. -/
def focus (id : String) : Cmd Msg := .exec (focusById id)
/-- Keep `value` in local storage under `key`. -/
def store (key value : String) : Cmd Msg := .exec (storageSet key value)
/-- Read `key` from local storage; the value (or `none`) arrives as a message. -/
def load (key : String) (toMsg : Option String → Msg) : Cmd Msg := .task ((storageGet key).map (some ∘ toMsg))
/-- A random number below `bound`, as a message: `update` itself stays pure. -/
def random (bound : Nat) (toMsg : Nat → Msg) : Cmd Msg := .task ((randomBelow bound).map (some ∘ toMsg))
/-- The time in epoch milliseconds, as a message. -/
def now (toMsg : Nat → Msg) : Cmd Msg := .task (nowMs.map (some ∘ toMsg))

end Cmd

/-- What a component listens to, given its state. After each commit the host compares the keys
of `subscriptions props model` with the running ones: it starts new keys, stops missing ones and
keeps the rest (their decoders are the ones they started with, so keep model-dependent logic in
`update`, or put what it depends on in the key). -/
inductive Sub (Msg : Type) where
  | none
  | batch (subscriptions : List (Sub Msg))
  /-- A host event source: `start emit` begins sending messages through `emit` and returns how
  to stop. The bridge for host streams (a game's move feed keyed by game id). -/
  | source (key : String) (start : (Msg → Action Unit) → Action (Action Unit))

@[leanjs_stack_safe] def Sub.map (f : α → β) : Sub α → Sub β
  | .none => .none
  | .batch subscriptions => .batch (subscriptions.map (Sub.map f))
  | .source key start => .source key fun emit => start (emit ∘ f)

/-- The sources, first occurrence of each key. -/
@[leanjs_stack_safe] def Sub.sources : Sub Msg → List (String × ((Msg → Action Unit) → Action (Action Unit)))
  | .none => []
  | .batch subscriptions => subscriptions.flatMap Sub.sources
  | .source key start => [(key, start)]

namespace Sub
open Effects

/-- The time (epoch milliseconds) every `ms` milliseconds. -/
def every (ms : Nat) (toMsg : Nat → Msg) : Sub Msg :=
  .source s!"every:{ms}" fun emit => Effects.every ms (do emit (toMsg (← nowMs)))

/-- Document-level key presses (`key` distinguishes several key subscriptions). -/
def onKey (toMsg : KeyEvent → Option Msg) (key : String := "keys") : Sub Msg :=
  .source key fun emit => onDocumentKeyDown fun e => match toMsg e with
    | some msg => emit msg
    | Option.none => pure ()

end Sub

end LeanReact.Program
