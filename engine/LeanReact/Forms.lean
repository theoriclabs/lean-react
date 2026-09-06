import LeanReact.Core
import LeanOntology.Validation

namespace LeanReact

/-- Parsing human input is separate from formatting a valid value. Invalid raw values are retained. -/
structure DraftParser (Raw Value : Type) where
  parse : Raw → Ontology.Validation Value
  format : Value → Raw

namespace DraftParser

def identity : DraftParser α α := ⟨Except.ok, id⟩

def ofExcept (parse : Raw → Except Error Value) (format : Value → Raw)
    (error : Error → Ontology.ValidationErrors) : DraftParser Raw Value :=
  ⟨fun raw => (parse raw).mapError error, format⟩

def map (parser : DraftParser Raw α) (forward : α → β) (backward : β → α) : DraftParser Raw β :=
  ⟨fun raw => (parser.parse raw).map forward, fun value => parser.format (backward value)⟩

def checked (parser : DraftParser Raw α) (validate : α → Ontology.Validation β)
    (project : β → α) : DraftParser Raw β :=
  ⟨fun raw => parser.parse raw >>= validate, fun value => parser.format (project value)⟩

def atPath (parser : DraftParser Raw Value) (path : Ontology.FieldPathId) : DraftParser Raw Value :=
  ⟨fun raw => Ontology.Validation.prependPath path (parser.parse raw), parser.format⟩

/-- Independent fields accumulate errors. Dependent validation can follow with `checked`. -/
def product (left : DraftParser RawA A) (right : DraftParser RawB B) : DraftParser (RawA × RawB) (A × B) :=
  ⟨fun raw => Ontology.Validation.map2 Prod.mk (left.parse raw.1) (right.parse raw.2),
    fun value => (left.format value.1, right.format value.2)⟩

def optional (parser : DraftParser Raw Value) : DraftParser (Option Raw) (Option Value) :=
  ⟨fun raw => match raw with | none => .ok none | some raw => (parser.parse raw).map some,
    fun value => value.map parser.format⟩

/-- Every failing item is reported at its array index; malformed raw items are never discarded. -/
def list (parser : DraftParser Raw Value) : DraftParser (Array Raw) (Array Value) :=
  ⟨fun raws => Id.run do
    let mut result : Ontology.Validation (Array Value) := .ok #[]
    let mut index := 0
    for raw in raws do
      let item := Ontology.Validation.prependPath [.index index] (parser.parse raw)
      index := index + 1
      result := Ontology.Validation.map2 (fun values value => values.push value) result item
    return result,
    fun values => values.map parser.format⟩

end DraftParser

structure Draft (Raw Value : Type) where
  raw : Raw
  parsed : Ontology.Validation Value

namespace Draft

def create (parser : DraftParser Raw Value) (raw : Raw) : Draft Raw Value := ⟨raw, parser.parse raw⟩
def replace (parser : DraftParser Raw Value) (raw : Raw) (_previous : Draft Raw Value) : Draft Raw Value :=
  create parser raw

def errors (draft : Draft Raw Value) : Option Ontology.ValidationErrors :=
  match draft.parsed with | .ok _ => none | .error errors => some errors

end Draft

/-- An ordinary controlled field. `modify` always transforms the owner's latest state. -/
structure FieldBinding (Raw : Type) where
  value : Raw
  set : Raw → Action Unit
  modify : (Raw → Raw) → Action Unit

namespace FieldBinding

def ofState (state : State α) : FieldBinding α := ⟨state.value, state.set, state.modify⟩

/-- Adapt a complete field representation. For preserving sibling fields, use `focus`. -/
def map (binding : FieldBinding α) (forward : α → β) (backward : β → α) : FieldBinding β := {
  value := forward binding.value
  set := fun value => binding.set (backward value)
  modify := fun update => binding.modify (fun latest => backward (update (forward latest)))
}

def focus (binding : FieldBinding α) (lens : Ontology.Lens α β) : FieldBinding β := {
  value := lens.get binding.value
  set := fun value => binding.modify (fun latest => lens.set latest value)
  modify := fun update => binding.modify (lens.modify update)
}

def draft (binding : FieldBinding Raw) (parser : DraftParser Raw Value) : Draft Raw Value :=
  Draft.create parser binding.value

/-- Retained bindings do not resurrect an optional child after it has been cleared. -/
def present (binding : FieldBinding (Option α)) : Option (FieldBinding α) :=
  binding.value.map fun value => {
    value
    set := fun next => binding.modify (fun latest => latest.map (fun _ => next))
    modify := fun update => binding.modify (fun latest => latest.map update)
  }

/-- Key-based updates follow reorder and become no-ops if the item has been removed.
The owning collection must have unique keys, as checked by `Editor.list`/`keyedEach`. -/
def item (binding : FieldBinding (Array α)) (keyOf : α → Key) (key : Key) : Option (FieldBinding α) :=
  (binding.value.find? (fun value => keyOf value == key)).map fun value => {
    value
    set := fun next => binding.modify (fun latest => latest.map (fun item => if keyOf item == key then next else item))
    modify := fun update => binding.modify (fun latest => latest.map (fun item => if keyOf item == key then update item else item))
  }

end FieldBinding

abbrev Editor (Raw : Type) := Component (FieldBinding Raw)

structure OptionalEditorModel where
  present : Bool
  child : Element
  enable : Action Unit
  clear : Action Unit

namespace Editor

/-- Editor composition is ordinary prop adaptation; hoist the resulting component definition. -/
def map (editor : Editor β) (adapt : FieldBinding α → FieldBinding β) : Editor α :=
  component fun binding => pure <| element editor (adapt binding)

def optional (editor : Editor α) (initial : α) (layout : OptionalEditorModel → Element) : Editor (Option α) :=
  component fun binding => pure <| layout {
    present := binding.value.isSome
    child := match binding.present with | none => empty | some child => element editor child
    enable := binding.modify (fun latest => match latest with | none => some initial | some value => some value)
    clear := binding.set none
  }

/-- Rows and their layout are caller-supplied render functions, not a widget registry. -/
def list (keyOf : α → Key) (row : FieldBinding α → Action Unit → Element)
    (layout : Element → (α → Action Unit) → Element) : Editor (Array α) :=
  component fun binding => pure <| layout
    (keyedEach binding.value keyOf fun value =>
      match binding.item keyOf (keyOf value) with
      | none => empty
      | some child => row child (binding.modify (fun latest => latest.filter (fun item => keyOf item != keyOf value))))
    (fun value => binding.modify (fun latest => latest.push value))

end Editor

structure Form (Raw Value : Type) where
  draft : Draft Raw Value
  binding : FieldBinding Raw
  read : Action (Draft Raw Value)
  reset : Action Unit

/-- One raw state cell; changing parser/initial props does not silently overwrite edits.
Reset explicitly restores the initial value from the render that supplied that reset Action. -/
def useForm (parser : DraftParser Raw Value) (initial : Raw) (site : String := "") : Hook (Form Raw Value) := do
  let state ← useState initial site
  pure {
    draft := Draft.create parser state.value
    binding := FieldBinding.ofState state
    read := Action.map (Draft.create parser) state.read
    reset := state.set initial
  }

namespace Form

def validate (form : Form Raw Value) : Action (Ontology.Validation Value) := do
  pure (← form.read).parsed

/-- Invalid input never calls `onValid` and remains in the draft. -/
def submit (form : Form Raw Value) (onValid : Value → Action α) : Action (Ontology.Validation α) := do
  match ← form.validate with
  | .error errors => pure (.error errors)
  | .ok value => pure (.ok (← onValid value))

end Form

end LeanReact
