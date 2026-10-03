import LeanReact.Resources
import LeanApp.Domain.Scalars

namespace LeanReact.Domain
open LeanApp.Domain Ontology

/-- Scope includes nominal resource, live actor, and auth/policy invalidation generations. -/
structure ResourceScope (Resource Actor : Type) where
  resource : Ref Resource
  actor : Option (Ref Actor)
  authGeneration : Nat
  policyGeneration : Nat := 0

def referenceKey [HasTypeId T] (value : Ref T) : String :=
  let identity := HasTypeId.typeId (α := T)
  (Key.inSpace identity.packageName (Key.inSpace identity.name
    (Key.inSpace value.scope.value value.key).value).value).value

def ResourceScope.key {R A : Type} [HasTypeId R] [HasTypeId A] (scope : ResourceScope R A) : Key :=
  let actor := scope.actor.map referenceKey |>.getD "anonymous"
  Key.inSpace (referenceKey scope.resource)
    (Key.inSpace actor s!"{scope.authGeneration}:{scope.policyGeneration}").value

/-- Uses the existing cancellation/generation machinery; no shared cache or local persistence. -/
def useScopedResource [HasTypeId R] [HasTypeId A] (scope : ResourceScope R A)
    (loader : ResourceRequest → Action (Except Error Value)) (site : String := "") : Hook (Resource Value Error) :=
  useResource scope.key loader #[] true site

/-- Pure scope changes immediately discard old payloads before a replacement request begins. -/
structure ScopedTracker (R A Value Error : Type) where
  scope : ResourceScope R A
  tracker : ResourceTracker Value Error := {}

def ScopedTracker.rebind [HasTypeId R] [HasTypeId A] (next : ResourceScope R A)
    (current : ScopedTracker R A V E) : ScopedTracker R A V E :=
  if next.key == current.scope.key then current else ⟨next, current.tracker.cancel⟩

def ScopedTracker.begin [HasTypeId R] [HasTypeId A] (current : ScopedTracker R A V E) :
    ResourceToken × ScopedTracker R A V E :=
  let (token, tracker) := current.tracker.begin current.scope.key
  (token, { current with tracker })

end LeanReact.Domain
