import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
def wrong (guests : Disclosure (List Guest)) : Element := list guests fun guest => text guest.name
end Partiful
