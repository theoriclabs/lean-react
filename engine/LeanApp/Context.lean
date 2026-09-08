namespace LeanApp

/-- Claims supplied by a trusted host, not evidence of authentication by themselves. -/
structure Principal where
  actor : String
  tenant : String
  sessionGeneration : Nat
  deriving Repr, BEq

/-- No Wire/FromJson instance: client input never issues authority. -/
structure RequestContext where
  private mk ::
  principal : Option Principal
  requestId : String

def RequestContext.anonymous (requestId : String) : RequestContext :=
  ⟨none, requestId⟩

namespace TrustedNative
/-- Explicit trusted escape hatch. The caller must authenticate and validate claims first.
This is API separation, not a sandbox against arbitrary Lean code importing this function. -/
def issueContext (principal : Principal) (requestId : String) : RequestContext :=
  ⟨some principal, requestId⟩
end TrustedNative
end LeanApp
