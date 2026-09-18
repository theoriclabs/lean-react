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

/-- Depth-first search for the first node accepted by `accept`, returning its recorded attributes. -/
partial def RenderedTree.findNode? (tree : LeanReact.RenderedTree) (accept : String → Array Attribute → Bool) :
    Option (Array Attribute) :=
  match tree with
  | .text _ => none
  | .node tag attributes children =>
    if accept tag attributes then some attributes else children.findSome? (findNode? · accept)
  | .fragment children => children.findSome? (findNode? · accept)
  | .keyed _ child | .child _ _ child => findNode? child accept

def attribute? (attributes : Array Attribute) (name : String) : Option String :=
  attributes.findSome? fun attr => match attr with
    | .string attrName value => if attrName == name then some value else none
    | _ => none

def RenderedTree.byId? (tree : LeanReact.RenderedTree) (id : String) : Option (Array Attribute) :=
  RenderedTree.findNode? tree fun _ attributes => attribute? attributes "id" == some id
def RenderedTree.byTag? (tree : LeanReact.RenderedTree) (tag : String) : Option (Array Attribute) :=
  RenderedTree.findNode? tree fun nodeTag _ => nodeTag == tag
def RenderedTree.byTestId? (tree : LeanReact.RenderedTree) (testId : String) : Option (Array Attribute) :=
  RenderedTree.findNode? tree fun _ attributes => attribute? attributes "data-testid" == some testId

/-- Event dispatch on one inspected node's attributes: every matching handler runs in attribute order.
This models a single target, not browser bubbling; `dispatchSubmit` stands for an already prevented default. -/
def dispatchPress (attributes : Array Attribute) (event : PressEvent := {}) : IO Unit := do
  for attr in attributes do if let .press handler := attr then (handler event).runIO
def dispatchChange (attributes : Array Attribute) (event : ChangeEvent) : IO Unit := do
  for attr in attributes do if let .change handler := attr then (handler event).runIO
def dispatchInput (attributes : Array Attribute) (event : InputEvent) : IO Unit := do
  for attr in attributes do if let .input handler := attr then (handler event).runIO
def dispatchPaste (attributes : Array Attribute) (event : PasteEvent) : IO Unit := do
  for attr in attributes do if let .paste handler := attr then (handler event).runIO
def dispatchFocus (attributes : Array Attribute) (event : FocusEvent := {}) : IO Unit := do
  for attr in attributes do if let .focus handler := attr then (handler event).runIO
def dispatchBlur (attributes : Array Attribute) (event : FocusEvent := {}) : IO Unit := do
  for attr in attributes do if let .blur handler := attr then (handler event).runIO
def dispatchKeyUp (attributes : Array Attribute) (event : KeyEvent) : IO Unit := do
  for attr in attributes do if let .keyUp handler := attr then (handler event).runIO
def dispatchSubmit (attributes : Array Attribute) : IO Unit := do
  for attr in attributes do if let .submit handler := attr then handler.runIO
/-- The recorded outcome: any handler asking to prevent the default wins, as in the browser. -/
def dispatchKeyDown (attributes : Array Attribute) (event : KeyEvent) : IO KeyOutcome := do
  let mut outcome := KeyOutcome.continue
  for attr in attributes do
    if let .keyDown handler := attr then
      if (← (handler event).runIO) == .preventDefault then outcome := .preventDefault
  pure outcome

end LeanReact.Reference
