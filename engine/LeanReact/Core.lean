import Lean

namespace LeanReact

/-- Deferred host work. Native IO is only available through the explicit reference adapter. -/
structure Action (α : Type) where
  ofIO ::
  runIO : IO α

namespace Action

def pure (value : α) : Action α := ⟨Pure.pure value⟩
def bind (first : Action α) (next : α → Action β) : Action β :=
  ⟨first.runIO >>= fun value => (next value).runIO⟩
instance : Monad Action where
  pure := Action.pure
  bind := Action.bind

def map (f : α → β) (work : Action α) : Action β := do pure (f (← work))
def catchError (work : Action α) (recover : IO.Error → Action α) : Action α :=
  ⟨try work.runIO catch error => (recover error).runIO⟩

end Action

structure Key where
  value : String
  deriving Repr, BEq, DecidableEq

namespace Key

def string (value : String) : Key := ⟨value⟩
def nat (value : Nat) : Key := ⟨toString value⟩
/-- Length-prefix the namespace so pairs cannot collide through separators. -/
def inSpace (space id : String) : Key := ⟨s!"{space.length}:{space}{id}"⟩

end Key

inductive Dependency where
  | string (value : String)
  | nat (value : Nat)
  | int (value : Int)
  | bool (value : Bool)
  deriving Repr, BEq

structure HookSite where
  kind : String
  label : String := ""
  deriving Repr, BEq

/-- A committed trace or a compiler-produced plan can be compared with this render. -/
def validateHookTrace (expected actual : Array HookSite) : Except String Unit :=
  if expected == actual then .ok ()
  else .error s!"LeanReact hook placement changed: expected {repr expected}, received {repr actual}"

/-- Native in-memory history for the reference renderer; entries are `pathname + search` strings. -/
structure History where
  entries : IO.Ref (Array String)
  index : IO.Ref Nat

namespace History

def create (initial : String := "/") : IO History := do
  pure ⟨← IO.mkRef #[initial], ← IO.mkRef 0⟩
def current (history : History) : IO String := do
  return (← history.entries.get).getD (← history.index.get) "/"
/-- Drops any forward entries, like the browser. -/
def push (history : History) (path : String) : IO Unit := do
  let index ← history.index.get
  history.entries.modify fun entries => (entries.extract 0 (index + 1)).push path
  history.index.set (index + 1)
def replace (history : History) (path : String) : IO Unit := do
  history.entries.modify (·.set! (← history.index.get) path)
def back (history : History) : IO Unit := do
  let index ← history.index.get
  if index > 0 then history.index.set (index - 1)
def forward (history : History) : IO Unit := do
  let index ← history.index.get
  if index + 1 < (← history.entries.get).size then history.index.set (index + 1)

end History

/-- Native-only interpreter data. The browser adapter does not compile this representation. -/
structure RenderEnv where
  trace : IO.Ref (Array HookSite)
  effects : IO.Ref (Array (Action (Action Unit)))
  contexts : Array (String × Dynamic) := #[]
  history : History

structure Hook (α : Type) where
  ofRender ::
  runRender : RenderEnv → IO α

namespace Hook

def pure (value : α) : Hook α := ⟨fun _ => Pure.pure value⟩
def bind (first : Hook α) (next : α → Hook β) : Hook β :=
  ⟨fun env => first.runRender env >>= fun value => (next value).runRender env⟩
instance : Monad Hook where
  pure := Hook.pure
  bind := Hook.bind

def map (f : α → β) (work : Hook α) : Hook β := do pure (f (← work))
def mark (kind site : String) : Hook Unit :=
  ⟨fun env => env.trace.modify (·.push ⟨kind, site⟩)⟩

end Hook

structure State (α : Type) where
  value : α
  set : α → Action Unit
  modify : (α → α) → Action Unit
  /-- Read at action time: the latest committed React value, or the native reference cell. -/
  read : Action α

/-- The native reference allocates one cell per invocation; React owns persistent mount slots. -/
def useState (initial : α) (site : String := "") : Hook (State α) := ⟨fun env => do
  (Hook.mark "state" site).runRender env
  let cell ← IO.mkRef initial
  pure {
    value := initial
    set := fun value => ⟨cell.set value⟩
    modify := fun update => ⟨cell.modify update⟩
    read := ⟨cell.get⟩
  }⟩

/-- Setup returns a deferred cleanup. Native reference runs setup only on explicit commit. -/
def useEffect (dependencies : Array Dependency) (setup : Action (Action Unit))
    (site : String := "") : Hook Unit := ⟨fun env => do
  let _ := dependencies
  (Hook.mark "effect" site).runRender env
  env.effects.modify (·.push setup)⟩

/-- Context carries native packing functions, keeping TypeName out of consumer signatures. -/
structure Context (α : Type) where
  name : String
  defaultValue : α
  pack : α → Dynamic
  unpack : Dynamic → Option α

/-- Use a unique, stable name per context declaration. TypeName is only for the native adapter. -/
def createContext [TypeName α] (name : String) (defaultValue : α) : Context α :=
  ⟨name, defaultValue, Dynamic.mk, fun value => Dynamic.get? α value⟩

def useContext (context : Context α) (site : String := "") : Hook α := ⟨fun env => do
  (Hook.mark "context" site).runRender env
  for (name, value) in env.contexts.reverse do
    if name == context.name then
      match context.unpack value with
      | some value => return value
      | none => throw <| IO.userError s!"LeanReact context type mismatch: {context.name}"
  pure context.defaultValue⟩

/-- A small immutable event snapshot; it never retains React's mutable event object. -/
structure PressEvent where
  alt : Bool := false
  ctrl : Bool := false
  metaKey : Bool := false
  shift : Bool := false
  deriving Repr, BEq

structure ChangeEvent where
  value : String
  checked : Bool := false
  deriving Repr, BEq

structure KeyEvent where
  key : String
  alt : Bool := false
  ctrl : Bool := false
  metaKey : Bool := false
  shift : Bool := false
  /-- The key is held down and the browser is auto-repeating it (`«repeat»` in structure instances). -/
  «repeat» : Bool := false
  deriving Repr, BEq

/-- Whether a key handler stops the browser default. Only a synchronous result can prevent it. -/
inductive KeyOutcome where
  | «continue»
  | preventDefault
  deriving Repr, BEq, DecidableEq

/-- A `KeyEvent → Action Unit` handler still type-checks as a key handler and means `.continue`. -/
instance : Coe Unit KeyOutcome := ⟨fun _ => .continue⟩
instance : Coe (Action Unit) (Action KeyOutcome) := ⟨Action.map fun _ => .continue⟩
instance : Coe (KeyEvent → Action Unit) (KeyEvent → Action KeyOutcome) :=
  ⟨fun handler event => (handler event).map fun _ => .continue⟩

/-- `value` is the control's current value, or `""` for elements without one. -/
structure FocusEvent where
  value : String := ""
  deriving Repr, BEq

/-- Live text input. `isComposing` is true during an IME composition session. -/
structure InputEvent where
  value : String
  isComposing : Bool := false
  deriving Repr, BEq

/-- Clipboard contents snapshotted synchronously; `html` is absent for plain-text pastes. -/
structure PasteEvent where
  text : String
  html : Option String := none
  deriving Repr, BEq

/-- Scroll offsets in whole CSS pixels. -/
structure ScrollEvent where
  scrollTop : Int := 0
  scrollLeft : Int := 0
  deriving Repr, BEq

inductive Attribute where
  | string (name value : String)
  | bool (name : String) (value : Bool)
  | press (handler : PressEvent → Action Unit)
  | change (handler : ChangeEvent → Action Unit)
  | keyDown (handler : KeyEvent → Action KeyOutcome)
  | keyUp (handler : KeyEvent → Action Unit)
  | focus (handler : FocusEvent → Action Unit)
  | blur (handler : FocusEvent → Action Unit)
  | input (handler : InputEvent → Action Unit)
  | paste (handler : PasteEvent → Action Unit)
  | mouseEnter (handler : PressEvent → Action Unit)
  | mouseLeave (handler : PressEvent → Action Unit)
  | scroll (handler : ScrollEvent → Action Unit)
  /-- The browser default (navigation) is always prevented before the handler runs. -/
  | submit (handler : Action Unit)
  /-- Inline style entries with React's camelCase property names. -/
  | style (entries : Array (String × String))
  /-- An anchor click handled in place: unmodified primary clicks on same-origin `href`s prevent the
  browser navigation and run the handler; other clicks keep the default. -/
  | navigate (handler : Action Unit)

/-- A fully evaluated native inspection tree. It is not the browser representation. -/
inductive RenderedTree where
  | text (value : String)
  | node (tag : String) (attributes : Array Attribute) (children : Array RenderedTree)
  | fragment (children : Array RenderedTree)
  | keyed (key : Key) (child : RenderedTree)
  | child (name : String) (trace : Array HookSite) (tree : RenderedTree)

/-- An unevaluated tree. Constructing it never calls child hooks or actions. -/
structure Element where
  renderTree : RenderEnv → IO RenderedTree

structure Component (Props : Type) where
  render : Props → Hook Element
  name : String := "Anonymous"

def component (render : Props → Hook Element) : Component Props := ⟨render, "Anonymous"⟩
def Component.named (name : String) (value : Component Props) : Component Props :=
  { value with name }
def element (value : Component Props) (props : Props) : Element := ⟨fun env => do
  let trace ← IO.mkRef #[]
  let childEnv := { env with trace }
  let child ← (value.render props).runRender childEnv
  let tree ← child.renderTree childEnv
  pure <| .child value.name (← trace.get) tree⟩
def text (value : String) : Element := ⟨fun _ => pure <| .text value⟩
def node (tag : String) (attributes : Array Attribute) (children : Array Element) : Element :=
  ⟨fun env => return .node tag attributes (← children.mapM (·.renderTree env))⟩
def fragment (children : Array Element) : Element :=
  ⟨fun env => return .fragment (← children.mapM (·.renderTree env))⟩
def empty : Element := fragment #[]
def keyed (key : Key) (child : Element) : Element :=
  ⟨fun env => return .keyed key (← child.renderTree env)⟩

def keyedEach (items : Array α) (key : α → Key) (row : α → Element) : Element :=
  ⟨fun env => do
    let mut seen : Array Key := #[]
    let mut children : Array RenderedTree := #[]
    for item in items do
      let itemKey := key item
      if seen.contains itemKey then
        throw <| IO.userError s!"LeanReact duplicate sibling key: {itemKey.value}"
      seen := seen.push itemKey
      children := children.push (.keyed itemKey (← (row item).renderTree env))
    pure <| .fragment children⟩

def provide (context : Context α) (value : α) (child : Element) : Element :=
  ⟨fun env => child.renderTree { env with contexts := env.contexts.push (context.name, context.pack value) }⟩

structure ProviderProps (α : Type) where
  value : α
  children : Element

def provider (context : Context α) : Component (ProviderProps α) :=
  Component.named s!"{context.name}.Provider" <| component fun props =>
    pure <| provide context props.value props.children

end LeanReact
