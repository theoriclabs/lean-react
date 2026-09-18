import LeanApp.Binding

/-! Reusable access rules. Each carries the description published under `metadata.describePolicy`,
so reviewers and clients see the intended rule, not only its effect. -/
namespace LeanApp.Policy
open Contract

variable {m : Type → Type} {Read : Type → Type} {operation : Operation kind Input Output Error}

/-- Any principal issued by the trusted host. -/
def authenticated [Pure m] : Rule m Read operation where
  policy context _ _ := pure <| if context.principal.isSome then .ok () else .error .unauthenticated
  describePolicy := "authenticated"

/-- Applications supply `roleOf` once; each binding states its minimum. `roleOf` may read the
resource through the capability. A missing role (no membership, or no resource) answers
`onMissing`, so probes cannot separate the two cases; when the response must stay uniform with
other failures, let `roleOf` answer `some` for existing members and route existence to the
handler's typed `notFound` instead. -/
def requireRole [Monad m] [Ord ρ] [ToString ρ] (minimum : ρ)
    (roleOf : RequestContext → ReadCapability m Read → Input → m (Option ρ))
    (onMissing : CallError Empty := .forbidden) : Rule m Read operation where
  policy context cap input := do
    if context.principal.isNone then return .error .unauthenticated
    match ← roleOf context cap input with
    | none => return .error onMissing
    | some role => return if compare minimum role != .gt then .ok () else .error .forbidden
  describePolicy := s!"role ≥ {minimum}"

def both [Monad m] (p q : Rule m Read operation) : Rule m Read operation where
  policy context cap input := do
    match ← p.policy context cap input with
    | .error error => return .error error
    | .ok () => q.policy context cap input
  describePolicy := s!"{p.describePolicy} and {q.describePolicy}"

/-- Owner or admin. When both refuse, the first rule's error is reported. -/
def either [Monad m] (p q : Rule m Read operation) : Rule m Read operation where
  policy context cap input := do
    match ← p.policy context cap input with
    | .ok () => return .ok ()
    | .error first =>
      match ← q.policy context cap input with
      | .ok () => return .ok ()
      | .error _ => return .error first
  describePolicy := s!"{p.describePolicy} or {q.describePolicy}"

/-- Explicitly not published to callers, while the binding stays in the manifest. -/
def deny [Pure m] : Rule m Read operation where
  policy _ _ _ := pure (.error .forbidden)
  describePolicy := "deny"

/-- Select a rule from the typed input. The description cannot be derived, so state it. -/
def withInput (describePolicy : String) (choose : Input → Rule m Read operation) :
    Rule m Read operation where
  policy context cap input := (choose input).policy context cap input
  describePolicy := describePolicy

end LeanApp.Policy
