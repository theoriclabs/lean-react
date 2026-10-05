import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
def absent : ResourceFamily := { entity := fun _ => ULift Empty, member := fun _ _ _ => ULift Empty, projection := fun _ _ => ULift Empty, auth := fun _ => ULift Empty }
def wrong : host.Requirements absent := host.Requirements.infer
end Partiful
