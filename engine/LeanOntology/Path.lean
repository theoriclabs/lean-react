import Std

namespace Ontology

/-- A stable semantic identity; source names and wire names may differ. -/
structure TypeId where
  packageName : String
  name : String
  deriving Repr, BEq, DecidableEq

class HasTypeId (α : Type u) where
  typeId : TypeId

/-- Semantic fields and wire keys deliberately have different constructors. -/
inductive PathSegment where
  | field (owner : TypeId) (name : String)
  | key (name : String)
  | index (value : Nat)
  | variant (tag : String)
  deriving Repr, BEq, DecidableEq

abbrev FieldPathId := List PathSegment

structure FieldPath (Source : Type u) (Value : Type v) where
  identity : FieldPathId
  get : Source → Value

namespace FieldPath

def id : FieldPath α α := ⟨[], fun a => a⟩

def field (owner : TypeId) (name : String) (get : α → β) : FieldPath α β :=
  ⟨[.field owner name], get⟩

def comp (outer : FieldPath α β) (inner : FieldPath β γ) : FieldPath α γ :=
  ⟨outer.identity ++ inner.identity, fun a => inner.get (outer.get a)⟩

end FieldPath

/-- Setters are a separate, explicitly supplied capability. -/
structure Lens (Source : Type u) (Value : Type v) extends FieldPath Source Value where
  set : Source → Value → Source

namespace Lens

def id : Lens α α := ⟨FieldPath.id, fun _ value => value⟩

def field (owner : TypeId) (name : String) (get : α → β)
    (set : α → β → α) : Lens α β :=
  ⟨FieldPath.field owner name get, set⟩

def comp (outer : Lens α β) (inner : Lens β γ) : Lens α γ :=
  ⟨outer.toFieldPath.comp inner.toFieldPath,
    fun source value => outer.set source (inner.set (outer.get source) value)⟩

def modify (lens : Lens α β) (f : β → β) (source : α) : α :=
  lens.set source (f (lens.get source))

/-- Optional evidence for consumers that need lawful replacement. -/
structure Laws (lens : Lens α β) : Prop where
  get_set : ∀ source value, lens.get (lens.set source value) = value
  set_get : ∀ source, lens.set source (lens.get source) = source
  set_set : ∀ source first second,
    lens.set (lens.set source first) second = lens.set source second

theorem id_laws : (id : Lens α α).Laws := ⟨by intros; rfl, by intros; rfl, by intros; rfl⟩

theorem Laws.comp {outer : Lens α β} {inner : Lens β γ}
    (ho : outer.Laws) (hi : inner.Laws) : (outer.comp inner).Laws := by
  constructor
  · intro source value
    change inner.get (outer.get (outer.set source (inner.set (outer.get source) value))) = value
    rw [ho.get_set, hi.get_set]
  · intro source
    change outer.set source (inner.set (outer.get source) (inner.get (outer.get source))) = source
    rw [hi.set_get, ho.set_get]
  · intro source first second
    change outer.set (outer.set source (inner.set (outer.get source) first))
      (inner.set (outer.get (outer.set source (inner.set (outer.get source) first))) second) = _
    rw [ho.get_set, ho.set_set, hi.set_set]
    rfl

end Lens
end Ontology
