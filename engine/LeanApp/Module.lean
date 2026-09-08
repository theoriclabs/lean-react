import LeanApp.Binding

namespace LeanApp

/-- Physical names must be canonicalized by the storage adapter (including database/schema).
Mapping IDs identify an agreed complete mapping, not merely an entity's display name. -/
structure StorageOwnership where
  physicalTable : String
  mappingId : String
  deriving Repr, BEq

structure Module (m : Type → Type) where
  name : String
  dependencies : List String := []
  metadata : PublicMetadata := {}
  exports : List (Export m) := []
  storage : List StorageOwnership := []

end LeanApp
