import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
command% fuller (me : SignedIn Person) (id : Ref Party) (available : Bool) : Unit := do
  let party ← find Party id else partyMissing
  require now < party.date else partyStarted
  require available else partyFull
  include me.id in party.guests
def wrong := form fuller onError fun
  | .partyMissing => notice "missing"
  | .partyStarted => notice "started"
end Partiful
