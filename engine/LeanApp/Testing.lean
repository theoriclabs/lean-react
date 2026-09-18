import LeanApp.Application

/-! ACL-matrix harness. Every (operation × caller) pair goes through the application's own
transport, so the observed answer is the one a host would return. Tests issue the contexts. -/
namespace LeanApp.Testing
open Contract

inductive CallerKind (ρ : Type) where
  | anonymous
  | role (role : ρ)
  | owner
  | otherTenant
  deriving Repr, BEq

def CallerKind.describe [ToString ρ] : CallerKind ρ → String
  | .anonymous => "anonymous"
  | .role r => s!"role {r}"
  | .owner => "owner"
  | .otherTenant => "other tenant"

inductive Expect where
  | allow
  | unauthenticated
  | forbidden
  | domainError (tag : String)
  deriving Repr, BEq

def Expect.describe : Expect → String
  | .allow => "allow"
  | .unauthenticated => "unauthenticated"
  | .forbidden => "forbidden"
  | .domainError tag => s!"domainError {tag}"

structure AclCase (ρ : Type) where
  operation : OperationId
  caller : CallerKind ρ
  input : Lean.Json
  expect : Expect

/-- The trusted context each caller kind receives. The harness never mints authority itself. -/
structure Fixture (ρ : Type) where
  context : CallerKind ρ → RequestContext

structure Failure (ρ : Type) where
  case : AclCase ρ
  observed : String

def observe (result : CallResult WireResponse Empty) : String :=
  match result with
  | .ok (.success _) => "allow"
  | .ok (.domainError value) => s!"domainError {value.compress}"
  | .error .unauthenticated => "unauthenticated"
  | .error .forbidden => "forbidden"
  | .error (.decode errors) => s!"decode {errors.first.code}"
  | .error (.protocol error) => s!"protocol {error.code}"
  | .error (.incompatible _) => "incompatible"
  | .error _ => "failure"

/-- `allow` means the policy admitted the call; a typed domain error still counts as admitted. -/
def Expect.matches (expect : Expect) (result : CallResult WireResponse Empty) : Bool :=
  match expect, result with
  | .allow, .ok _ => true
  | .unauthenticated, .error .unauthenticated => true
  | .forbidden, .error .forbidden => true
  | .domainError tag, .ok (.domainError value) =>
    value == .str tag || (value.getObjValAs? String "tag").toOption == some tag
  | _, _ => false

def runMatrix [Monad m] (app : Application m) (fixture : Fixture ρ)
    (cases : Array (AclCase ρ)) : m (Array (Failure ρ)) := do
  let mut failures := #[]
  for case in cases do
    let result ← match app.manifest.find? (·.operation.identity == case.operation) with
      | none => pure (.error (.protocol ⟨"operation.not_found", none, ""⟩))
      | some info =>
        (app.transport (fixture.context case.caller)).send ⟨case.operation, info.operation.kind, case.input⟩
    unless case.expect.matches result do failures := failures.push ⟨case, observe result⟩
  return failures

/-- Every approved operation × {anonymous, each role, another tenant}, judged by the declared
minimums. An operation without a minimum must deny every role. -/
def exhaustiveMatrix [Ord ρ] (app : Application m) (roles : List ρ)
    (minimums : OperationId → Option ρ) (sample : OperationId → Lean.Json) : Array (AclCase ρ) :=
  Id.run do
    let mut cases := #[]
    for info in app.manifest do
      let id := info.operation.identity
      let input := sample id
      cases := cases.push ⟨id, .anonymous, input, .unauthenticated⟩
      for role in roles do
        let expect := match minimums id with
          | some minimum => if compare minimum role != .gt then .allow else .forbidden
          | none => .forbidden
        cases := cases.push ⟨id, .role role, input, expect⟩
      cases := cases.push ⟨id, .otherTenant, input, .forbidden⟩
    return cases

/-- The minimum a `requireRole` binding publishes in `describePolicy`, so a matrix generated
from it fails whenever the description disagrees with the observed behaviour. -/
def describedMinimum [ToString ρ] (roles : List ρ) (info : PublicOperation) : Option ρ :=
  roles.find? fun role => info.metadata.describePolicy == s!"role ≥ {role}"

def report [ToString ρ] (failures : Array (Failure ρ)) : String :=
  String.intercalate "\n" (failures.toList.map fun failure =>
    let id := failure.case.operation
    s!"{id.namespaceName}.{id.name}@{id.version} {failure.case.caller.describe}: \
      expected {failure.case.expect.describe}, observed {failure.observed}")

end LeanApp.Testing
