import tests.domain.Evolution
open LeanReact.Domain
namespace Partiful
def hiddenFailures := form fuller onError fun error => match true with
  | .true => notice "all failures"
  | .false => notice "all failures"
end Partiful
