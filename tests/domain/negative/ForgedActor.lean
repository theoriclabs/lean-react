import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
def wrong (row : Row Unit Person) : SignedIn Unit Person := SignedIn.mk row
end Partiful
