import LeanReact.Core

namespace LeanReact

/-- The result of an imperative operation on a foreign component. `.unmounted` is the typed outcome of
calling a retained handle after its component unmounted; no host error is thrown. -/
inductive HandleResult (α : Type) where
  | ok (value : α)
  | unmounted
  deriving Repr, BEq

def HandleResult.toOption : HandleResult α → Option α
  | .ok value => some value
  | .unmounted => none

/-- A record of Actions owned by a mounted foreign component. In the browser every operation checks the
mount flag first and resolves to `.unmounted` afterwards, so a handle kept in a `Cell` can outlive its
component safely. Handle operations are Actions: they never run during render. -/
structure Handle (ops : Type) where
  ops : ops
  alive : Action Bool

/-- Native stand-in for a foreign component. The browser ignores this record; the host adapter registered
under the same name renders there. `ops` are the caller-supplied stubs behind the reference `Handle`;
without them the reference never calls `onReady`. Stubs run as given: only the browser runtime
enforces `.unmounted`. -/
structure ForeignReference (P H : Type) where
  render : P → Element := fun _ => empty
  ops : Option (P → H) := none

structure ForeignProps (P H : Type) where
  props : P
  /-- Called once per mount, after the first commit. -/
  onReady : Handle H → Action Unit
  /-- Called on unmount, and before a remount's `onReady`. -/
  onGone : Action Unit := pure ()
  reference : ForeignReference P H := {}

/-- A foreign component with a typed imperative handle. In the browser this is a compiler intrinsic
(arity 4: erased `P`, `H`, then `name`, `props`) resolved through `registerForeign(name, adapter)` in the
host adapter. Natively it renders `props.reference.render`, and `commit` hands `onReady` a Handle over
`props.reference.ops`; disposing the commit flips `alive` and runs `onGone`. -/
def foreign (name : String) (props : ForeignProps P H) : Element := ⟨fun env => do
  if let some ops := props.reference.ops then
    let mounted ← IO.mkRef false
    env.effects.modify (·.push ⟨do
      mounted.set true
      (props.onReady { ops := ops props.props, alive := ⟨mounted.get⟩ }).runIO
      pure ⟨do mounted.set false; props.onGone.runIO⟩⟩)
  let tree ← (props.reference.render props.props).renderTree env
  pure <| .child name #[] tree⟩

end LeanReact
