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

/-- Policy that yields evidence the handler cannot invent. -/
abbrev PolicyWith (m : Type → Type) (Read : Type → Type)
    (_ : Operation kind Input Output Error) (Ev : Type) :=
  RequestContext → ReadCapability m Read → Input → m (CallResult Ev Empty)

/-- Proof that `role` is at least `min`. Private constructor. -/
structure AtLeast (ρ : Type) [LE ρ] (min : ρ) where
  private mk ::
  role : ρ
  ok : min ≤ role

def AtLeast.mk? [LE ρ] [DecidableRel (· ≤ · : ρ → ρ → Prop)] (min role : ρ) :
    Option (AtLeast ρ min) :=
  if h : min ≤ role then some ⟨role, h⟩ else none

/-- Same workhorse as `requireRole`, but the handler receives `AtLeast` evidence. -/
def requireAtLeast [Monad m] [LE ρ] [DecidableRel (· ≤ · : ρ → ρ → Prop)] [ToString ρ]
    (minimum : ρ)
    (roleOf : RequestContext → ReadCapability m Read → Input → m (Option ρ))
    (onMissing : CallError Empty := .forbidden) :
    PolicyWith m Read operation (AtLeast ρ minimum) :=
  fun context cap input => do
    if context.principal.isNone then return .error .unauthenticated
    match ← roleOf context cap input with
    | none => return .error onMissing
    | some role =>
      match AtLeast.mk? minimum role with
      | some ev => return .ok ev
      | none => return .error .forbidden

/-- Issued principal, or unauthenticated. The handler cannot invent a `Principal`. -/
def authenticatedWith [Pure m] : PolicyWith m Read operation Principal :=
  fun context _ _ =>
    match context.principal with
    | some p => pure (.ok p)
    | none => pure (.error .unauthenticated)

def bothWith [Monad m] (p q : PolicyWith m Read operation Ev) : PolicyWith m Read operation Ev :=
  fun context cap input => do
    match ← p context cap input with
    | .error e => return .error e
    | .ok ev =>
      match ← q context cap input with
      | .ok _ => return .ok ev
      | .error e => return .error e

def eitherWith [Monad m] (p q : PolicyWith m Read operation Ev) : PolicyWith m Read operation Ev :=
  fun context cap input => do
    match ← p context cap input with
    | .ok ev => return .ok ev
    | .error first =>
      match ← q context cap input with
      | .ok ev => return .ok ev
      | .error _ => return .error first

/-- Binding whose policy yields evidence the handler cannot construct. -/
structure BindingE (m : Type → Type) (Read Write : Type → Type)
    (operation : Operation kind Input Output Error) (Ev : Type) where
  policy : PolicyWith m Read operation Ev
  handler : RequestContext → Capability m Read Write kind → Ev → Handler m operation
  http : HttpBinding
  metadata : PublicMetadata := {}
  describePolicy : String := ""

def BindingE.publicMetadata (binding : BindingE m Read Write operation Ev) : PublicMetadata :=
  if binding.describePolicy.isEmpty then binding.metadata
  else { binding.metadata with describePolicy := binding.describePolicy }

def BindingE.toRoute [Monad m] {operation : Operation kind Input Output Error}
    (binding : BindingE m Read Write operation Ev) (context : RequestContext)
    (cap : Capability m Read Write kind) : Route (Authorized m) :=
  Route.ofHandler operation fun input => ExceptT.mk do
    match ← binding.policy context (Capability.toRead cap) input with
    | .error error => pure (.error error)
    | .ok ev => pure (.ok (← binding.handler context cap ev input))

def BindingE.approve [Monad m] {operation : Operation kind Input Output Error}
    (binding : BindingE m Read Write operation Ev)
    (provide : RequestContext → Capability m Read Write kind) : Export m :=
  Export.of binding.http binding.publicMetadata fun context =>
    binding.toRoute context (provide context)

/-- `requireAtLeast` plus the published description, so a matrix can read the intended minimum. -/
def BindingE.atLeast [Monad m] [LE ρ] [DecidableRel (· ≤ · : ρ → ρ → Prop)] [ToString ρ]
    {operation : Operation kind Input Output Error}
    (minimum : ρ)
    (roleOf : RequestContext → ReadCapability m Read → Input → m (Option ρ))
    (http : HttpBinding)
    (handler : RequestContext → Capability m Read Write kind → AtLeast ρ minimum → Handler m operation)
    (onMissing : CallError Empty := .forbidden)
    (metadata : PublicMetadata := {}) :
    BindingE m Read Write operation (AtLeast ρ minimum) where
  policy := requireAtLeast minimum roleOf (onMissing := onMissing)
  handler := handler
  http := http
  metadata := metadata
  describePolicy := s!"role ≥ {minimum}"

/-- Select a rule from the typed input. The description cannot be derived, so state it. -/
def withInput (describePolicy : String) (choose : Input → Rule m Read operation) :
    Rule m Read operation where
  policy context cap input := (choose input).policy context cap input
  describePolicy := describePolicy

end LeanApp.Policy
