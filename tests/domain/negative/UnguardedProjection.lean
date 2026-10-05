import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
query% wrong (id : Ref Party) : List Name := do
  let party ← find Party id else partyMissing
  Flow.project (Projection.memberField (party.membersField "guests") "name")
end Partiful
