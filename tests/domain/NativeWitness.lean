/- Optional development integration fixture. Not imported by the portable package. -/
import tests.domain.Partiful
import LeanDbDomain.Schema
import LeanDbDomain.Access

namespace Partiful
native_schema% NativeSchema := Person, Party
end Partiful

namespace DomainNativeWitness
open LeanApp.Domain

@[reducible] def resources : ResourceFamily := LeanDb.Domain.storageResources Partiful.NativeSchema

#synth LeanDb.Domain.HasMemberStorage Partiful.NativeSchema Partiful.Party "guests" Partiful.Person
#synth HasProjectionResource (LeanDb.Domain.storageResources Partiful.NativeSchema) Partiful.Party Partiful.Person "guests"
  (LeanDb.Domain.HasMemberStorage.storage (s := Partiful.NativeSchema) (Parent := Partiful.Party) (field := "guests") (Target := Partiful.Person)) "name" Name
-- All requirements are synthesized from coherent generated dictionaries.
def hostRequirements : Partiful.host.Requirements resources := Partiful.host.Requirements.infer
def rsvpRequirements : Partiful.rsvp.Requirements resources := Partiful.rsvp.Requirements.infer
def pageRequirements : Partiful.partyPage.Requirements resources := Partiful.partyPage.Requirements.infer
#check Partiful.account.signUpProfile
#check Partiful.account.signUpPassword
#check Partiful.account.signInEmail
#check Partiful.account.signInPassword
-- Native auth evidence is API-owned; this DB-only fixture deliberately has none.

def hostBody {Scope : Type} (actor : SignedIn Scope Partiful.Person) (input : Partiful.host.Input) :=
  Partiful.host.bodyWithResources hostRequirements actor input

def pageBody {Scope : Type} (viewer : Viewer Scope Partiful.Person) (input : Partiful.partyPage.Input) :=
  Partiful.partyPage.bodyWithResources pageRequirements viewer input

/-- An arbitrary indexed find now supplies genuine native dictionaries, without recovering a Type. -/
def findHook {Scope T : Type} [Entity T] (storage : resources.entity T) (ref : Ref T) :
    Except String (LeanDb.Read Partiful.NativeSchema (Option (Row Scope T))) :=
  let _ := storage.entity
  let _ := storage.schema
  match LeanDb.Domain.refToId ref with
  | .error error => .error error
  | .ok id => .ok do
    let result ← LeanDb.Read.get T id
    pure (result.map fun value => Trusted.row ref value.val)

/-- The exact declared member witness supplies its existential Edge and coherent dictionaries. -/
def containsHook (relation : MemberHandle Scope P T resources) (person : Ref T) [Ontology.HasTypeId P]
    [Ontology.HasTypeId T] : Except String (LeanDb.Read Partiful.NativeSchema Bool) :=
  let storage := relation.storage
  let _ := storage.parent.entity
  let _ := storage.target.entity
  let _ := storage.edge.entity
  let _ := storage.edge.unique
  let _ := storage.edge.foreignKey
  let _ := storage.edge.schema
  let ids := do
    let parent ← LeanDb.Domain.refToId relation.parent
    let target ← LeanDb.Domain.refToId person
    pure (parent, target)
  match ids with
  | .error error => .error error
  | .ok (parent, target) => .ok (LeanDb.Read.memberContains storage.relation parent target)

/-- Uses the DB-owned generated coherent selection, reading only its column. -/
def projectHook (relation : MemberHandle Scope P T resources) (path : Ontology.FieldPath T V)
    (selection : resources.projection relation.storage path) :
    Except String (LeanDb.Read Partiful.NativeSchema (List V)) :=
  selection.project relation.parent

-- A native read interpreter can eliminate the existential T safely through its carried witness.
def findRequest {Scope E A : Type} : Request Scope E .query A resources →
    Option (Except String (LeanDb.Read Partiful.NativeSchema (Except E A)))
  | @RequestF.find _ _ _ _ T inst storage ref =>
    let _ : Entity T := inst
    some (match findHook storage ref with
      | .error error => .error error
      | .ok read => .ok do return .ok (← read))
  | _ => none
end DomainNativeWitness
