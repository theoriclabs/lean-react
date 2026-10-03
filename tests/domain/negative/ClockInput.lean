import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
command% badClock (now : Instant) : Unit := pure ()
end Partiful
