import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology Partiful
namespace Partiful
query% foreignIO (id : Ref Party) : Unit := do
  IO.println "unsupported"
end Partiful
