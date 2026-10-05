import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
query% writes (me : SignedIn Person) (id : Ref Party) : Unit := do
  let party ← find Party id else partyMissing
  remove party
end Partiful
