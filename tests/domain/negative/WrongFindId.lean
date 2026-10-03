import tests.domain.Partiful
open LeanApp.Domain Partiful
namespace Partiful
query% wrongFind (person : Ref Person) : Name := do
  let row ← find Party person else partyMissing
  pure row.name
end Partiful
