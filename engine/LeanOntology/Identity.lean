import LeanOntology.Validation

namespace Ontology

/-- A checked, nonempty scope. Equality is exact and case-sensitive. -/
structure IdentitySpace where
  private mk ::
  value : String
  deriving Repr, BEq, DecidableEq

def IdentitySpace.parse (value : String) : Validation IdentitySpace :=
  if value.isEmpty then Validation.fail "identity.empty_scope"
  else .ok ⟨value⟩

/-- The phantom entity parameter is nominal: IDs cannot be implicitly retargeted. -/
structure EntityId (Entity : Type u) where
  private mk ::
  scope : IdentitySpace
  key : String
  deriving Repr, BEq, DecidableEq

def EntityId.ofParts (scope : IdentitySpace) (key : String) : Validation (EntityId α) :=
  if key.isEmpty then Validation.fail "identity.empty_key"
  else .ok ⟨scope, key⟩

def EntityId.parse (scope key : String) : Validation (EntityId α) := do
  let scope ← IdentitySpace.parse scope
  EntityId.ofParts scope key

end Ontology
