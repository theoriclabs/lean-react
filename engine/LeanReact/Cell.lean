import LeanReact.Core

namespace LeanReact

/-- An immediate local capability, separate from React's queued render state. -/
structure Cell (α : Type) where
  private ofRef ::
  private reference : IO.Ref α

def Cell.read (cell : Cell α) : Action α := ⟨cell.reference.get⟩

/-- The pure transition returns `(result, nextValue)` in one local operation. -/
def Cell.modifyGet (cell : Cell α) (transition : α → β × α) : Action β :=
  ⟨cell.reference.modifyGet transition⟩

/-- Persistent per mount in React; native reference allocates one cell per invocation. -/
def useCell (initial : α) (site : String := "") : Hook (Cell α) := ⟨fun env => do
  (Hook.mark "cell" site).runRender env
  pure ⟨← IO.mkRef initial⟩⟩

end LeanReact
