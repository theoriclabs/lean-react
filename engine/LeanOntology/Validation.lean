import LeanOntology.Path

namespace Ontology

structure ValidationError where
  code : String
  path : FieldPathId := []
  params : List (String × String) := []
  deriving Repr, BEq, DecidableEq

/-- There is always at least one error. Prose belongs to a presentation. -/
structure ValidationErrors where
  first : ValidationError
  rest : List ValidationError := []
  deriving Repr, BEq, DecidableEq

namespace ValidationErrors

def single (code : String) (path : FieldPathId := [])
    (params : List (String × String) := []) : ValidationErrors :=
  ⟨⟨code, path, params⟩, []⟩

def toList (errors : ValidationErrors) : List ValidationError := errors.first :: errors.rest

def append (a b : ValidationErrors) : ValidationErrors :=
  ⟨a.first, a.rest ++ b.toList⟩

def prependPath (path : FieldPathId) (errors : ValidationErrors) : ValidationErrors :=
  let add := fun error => { error with path := path ++ error.path }
  ⟨add errors.first, errors.rest.map add⟩

end ValidationErrors

abbrev DecodeErrors := ValidationErrors
abbrev Validation (α : Type u) := Except ValidationErrors α
abbrev Validator (α : Type u) := α → Validation Unit

namespace Validation

def fail (code : String) (path : FieldPathId := [])
    (params : List (String × String) := []) : Validation α :=
  .error (ValidationErrors.single code path params)

def prependPath (path : FieldPathId) (result : Validation α) : Validation α :=
  result.mapError (ValidationErrors.prependPath path)

/-- Independent checks accumulate errors, in left-to-right order. -/
def map2 (f : α → β → γ) (a : Validation α) (b : Validation β) : Validation γ :=
  match a, b with
  | .ok x, .ok y => .ok (f x y)
  | .error x, .error y => .error (x.append y)
  | .error x, _ => .error x
  | _, .error y => .error y

end Validation

namespace Validator

def check (code : String) (predicate : α → Bool) : Validator α :=
  fun value => if predicate value then .ok () else Validation.fail code

def and (a b : Validator α) : Validator α :=
  fun value => Validation.map2 (fun _ _ => ()) (a value) (b value)

def contramap (get : α → β) (validator : Validator β) : Validator α :=
  fun value => validator (get value)

def atPath (path : FieldPath α β) (validator : Validator β) : Validator α :=
  fun value => Validation.prependPath path.identity (validator (path.get value))

end Validator

/-- Omission and clearing are different even for optional fields. -/
inductive PatchField (α : Type u) where
  | keep
  | set (value : α)
  deriving Repr, BEq, DecidableEq

def PatchField.apply (patch : PatchField α) (previous : α) : α :=
  match patch with
  | .keep => previous
  | .set value => value

end Ontology
