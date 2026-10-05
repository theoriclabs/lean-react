import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
inductive ExtendedVisibility where
  | «public» | attendees | «private» | hostsOnly
  deriving Domain
def wrong : ExtendedVisibility → String
  | .public => "public"
  | .attendees => "attendees"
  | .private => "private"
end Partiful
