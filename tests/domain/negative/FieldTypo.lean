import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
def wrong := form host onError fun | .dateMustBeFuture => fieldError .bogus "oops"
end Partiful
