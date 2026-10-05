import LeanApp.Domain.Metadata

namespace LeanApp.Domain

/-- A backend chooses typed capabilities. Portable declarations never import the backend. -/
structure ResourceFamily where
  entity : Type → Type 1
  member : Type → String → Type → Type 1
  /-- Evidence is anchored to the actual relation's native target dictionary. -/
  projection : {P T V : Type} → {name : String} → member P name T → Ontology.FieldPath T V → Type 1
  /-- Authentication storage is anchored to the exact native profile dictionary. -/
  auth : {T : Type} → entity T → Type 1
  /-- Native evidence for one declared unique constraint (`constraint T.name : unique …`),
  anchored to the exact entity dictionary. Portable/default: no evidence. A native family
  overrides this to carry the typed index whose key agrees with `UniqueKey.key`. -/
  unique : {T K : Type} → entity T → UniqueKey T K → Type 1 := fun _ _ => PUnit
  /-- Native evidence for a join through edge entity `E` (LeanDB: `LinkStorage`). -/
  link : {E P T : Type} → entity E → LinkKey E P T → Type 1 := fun _ _ => PUnit
  /-- Native evidence that one column of `T` holds the field at `path` (LeanDB: `HasFieldStorage`). -/
  column : {T V : Type} → entity T → Ontology.FieldPath T V → Type 1 := fun _ _ => PUnit

/-- Exact type evidence, supplied statically by the generated operation requirements. -/
class HasEntityResource (family : ResourceFamily) (T : Type) where
  witness : family.entity T

class HasMemberResource (family : ResourceFamily) (P : Type) (field : String) (T : Type) where
  witness : family.member P field T

class HasProjectionResource (family : ResourceFamily) (P T : Type) (member : String)
    (storage : family.member P member T) (field : String) (V : outParam Type) [EditableField T field V] where
  witness : family.projection storage (EditableField.lens (T := T) (field := field)).toFieldPath

class HasAuthResource (family : ResourceFamily) (T : Type) (storage : family.entity T) where
  witness : family.auth storage

/-- Typed lookup evidence for one declared unique constraint on the exact entity storage. -/
class HasUniqueResource (family : ResourceFamily) (T K : Type) (storage : family.entity T)
    (key : UniqueKey T K) where
  witness : family.unique storage key

/-- Typed join evidence for one generated `LinkKey` on the exact edge storage. -/
class HasLinkResource (family : ResourceFamily) (E P T : Type) (storage : family.entity E)
    (key : LinkKey E P T) where
  witness : family.link storage key

/-- Typed column evidence for one field path on the exact entity storage. -/
class HasColumnResource (family : ResourceFamily) (T V : Type) (storage : family.entity T)
    (path : Ontology.FieldPath T V) where
  witness : family.column storage path

def portableResources : ResourceFamily := {
  entity := fun _ => PUnit
  member := fun _ _ _ => PUnit
  projection := fun _ _ => PUnit
  auth := fun _ => PUnit
  unique := fun _ _ => PUnit
  link := fun _ _ => PUnit
  column := fun _ _ => PUnit
}
/- The portable instances are named: plain-operation publication abstracts exactly these
constants (and `portableResources`) to obtain the resource-generic body. -/
instance portableEntity : HasEntityResource portableResources T := ⟨PUnit.unit⟩
instance portableMember : HasMemberResource portableResources P field T := ⟨PUnit.unit⟩
instance portableProjection [EditableField T field V] (storage : portableResources.member P member T) :
    HasProjectionResource portableResources P T member storage field V := ⟨PUnit.unit⟩
instance portableAuth (storage : portableResources.entity T) : HasAuthResource portableResources T storage := ⟨PUnit.unit⟩
instance portableUnique (storage : portableResources.entity T) (key : UniqueKey T K) :
    HasUniqueResource portableResources T K storage key := ⟨PUnit.unit⟩
instance portableLink (storage : portableResources.entity E) (key : LinkKey E P T) :
    HasLinkResource portableResources E P T storage key := ⟨PUnit.unit⟩
instance portableColumn (storage : portableResources.entity T) (path : Ontology.FieldPath T V) :
    HasColumnResource portableResources T V storage path := ⟨PUnit.unit⟩
end LeanApp.Domain
