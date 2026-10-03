import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
def wrong {Scope : Type} (row : Row Scope Party) : Row Unit Party := row
end Partiful
