import tests.domain.Evolution
open LeanReact.Domain
namespace Partiful
def hiddenFailures := form fuller onError fun error => match error with
  | fallback => notice "all failures"
end Partiful
