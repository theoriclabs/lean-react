import LeanReact.Core

namespace LeanReact.Reference

/-- A prepared native render. Effects stay queued until `commit`. No DOM or reconciliation. -/
structure Prepared (α : Type) where
  value : α
  trace : Array HookSite
  effects : Array (Action (Action Unit))

private def environment : IO RenderEnv := do
  pure { trace := ← IO.mkRef #[], effects := ← IO.mkRef #[] }

def runHook (work : Hook α) : IO (Prepared α) := do
  let env ← environment
  let value ← work.runRender env
  pure ⟨value, ← env.trace.get, ← env.effects.get⟩

def render (value : Element) : IO (Prepared RenderedTree) := do
  let env ← environment
  let tree ← value.renderTree env
  pure ⟨tree, ← env.trace.get, ← env.effects.get⟩

def runAction (work : Action α) : IO α := work.runIO

/-- Setup runs in order. Unmount cleanup is idempotent and runs in reverse order.
If a setup fails, already acquired resources are cleaned up before propagating the error. -/
def Prepared.commit (prepared : Prepared α) : IO (Action Unit) := do
  let cleanups ← IO.mkRef (#[] : Array (Action Unit))
  let dispose : Action Unit := ⟨do
    let pending ← cleanups.get
    cleanups.set #[]
    let mut firstError : Option IO.Error := none
    for cleanup in pending.reverse do
      try cleanup.runIO catch error =>
        if firstError.isNone then firstError := some error
    if let some error := firstError then throw error⟩
  try
    for setup in prepared.effects do
      let cleanup ← setup.runIO
      cleanups.modify (·.push cleanup)
    pure dispose
  catch error =>
    try dispose.runIO catch _ => pure ()
    throw error

partial def RenderedTree.textContent : LeanReact.RenderedTree → String
  | .text value => value
  | .node _ _ children | .fragment children => String.join (children.toList.map textContent)
  | .keyed _ child | .child _ _ child => textContent child

end LeanReact.Reference
