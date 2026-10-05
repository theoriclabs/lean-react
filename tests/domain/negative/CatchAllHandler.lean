import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
def wrong := form rsvp onError fun error => notice "oops"
end Partiful
