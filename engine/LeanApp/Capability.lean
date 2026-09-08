import LeanContract

namespace LeanApp

/-- Selected, typed read operations; no write, raw connection, or IO lifting field. -/
structure ReadCapability (m : Type → Type) (Read : Type → Type) where
  read : {α : Type} → Read α → m α

/-- A host supplies writes only to command handlers. Transaction semantics belong to the host. -/
structure CommandCapability (m : Type → Type) (Read Write : Type → Type) where
  toRead : ReadCapability m Read
  write : {α : Type} → Write α → m α

def Capability (m : Type → Type) (Read Write : Type → Type) : Contract.OperationKind → Type 1
  | .query => ReadCapability m Read
  | .command => CommandCapability m Read Write

def Capability.toRead {kind : Contract.OperationKind}
    (cap : Capability m Read Write kind) : ReadCapability m Read :=
  match kind with
  | .query => cap
  | .command => CommandCapability.toRead cap

end LeanApp
