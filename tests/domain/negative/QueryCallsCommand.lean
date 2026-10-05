import tests.domain.Evolution
open LeanApp.Domain
namespace Composition
query% invalid (allowed : Bool) : Unit := do
  call callee () ⟨allowed⟩
end Composition
