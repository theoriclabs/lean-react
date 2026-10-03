import LeanApp.Domain
open LeanApp.Domain
namespace PartifulFixture
inductive GuestListVisibility where
  | «public» | attendees | «private»
  deriving Domain, BEq, Repr
@[entity] structure Person where
  name : Name
  email : Email
@[entity] structure Party where
  host : Ref Person
  title : Title
  date : Instant
  description : Text
  visibility : GuestListVisibility := .public
  guests : Members Person := {}
structure Guest where
  name : Name
  deriving Domain, BEq, Repr
structure PartyPage where
  title : Title
  date : Instant
  description : Text
  visibility : GuestListVisibility
  guests : Disclosure (List Guest)
  deriving Domain, BEq, Repr
#check (inferInstance : Ontology.Wire Guest)
#check (inferInstance : Entity Party)
#eval (Domain.fields (T := Party)).map fun f => (f.name, f.hasDefault)
end PartifulFixture
