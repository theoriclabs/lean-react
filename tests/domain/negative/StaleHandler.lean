import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
command% simpler (id : Ref Party) : Unit := do
  let _party ← find Party id else partyMissing
  pure ()
def wrong := form simpler onError fun
  | .partyMissing => notice "missing"
  | .partyStarted => notice "stale"
end Partiful
