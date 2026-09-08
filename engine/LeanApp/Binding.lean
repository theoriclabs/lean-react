import LeanApp.Context
import LeanApp.Capability

namespace LeanApp
open Contract Ontology

inductive HttpMethod where
  | post
  deriving Repr, BEq, DecidableEq

structure HttpBinding where
  path : String
  method : HttpMethod := .post
  deriving Repr, BEq

/-- Literal, canonical paths only. Adapters must match these exact paths without normalization. -/
def HttpBinding.validate (http : HttpBinding) : Validation Unit := do
  if !http.path.startsWith "/" ||
      (http.path != "/" && http.path.endsWith "/") ||
      (http.path.splitOn "/").any (fun s => s == "." || s == "..") ||
      (http.path != "/" && ((http.path.drop 1).toString.splitOn "/").contains "") ||
      !http.path.toList.all (fun c => c.isAlphanum && c.toNat < 128 ||
        c == '/' || c == '-' || c == '_' || c == '.') then
    Validation.fail "http.invalid_literal_path" [] [("path", http.path)]

structure PublicMetadata where
  title : String := ""
  description : String := ""
  deriving Repr, BEq

/-- Authority failures use Contract's error channel; domain errors stay in the handler. -/
abbrev Policy (m : Type → Type) (Read : Type → Type)
    (_ : Operation kind Input Output Error) :=
  RequestContext → ReadCapability m Read → Input → m (CallResult Unit Empty)

structure Binding (m : Type → Type) (Read Write : Type → Type)
    (operation : Operation kind Input Output Error) where
  policy : Policy m Read operation
  handler : RequestContext → Capability m Read Write kind → Handler m operation
  http : HttpBinding
  metadata : PublicMetadata := {}

def Binding.executionKind (_ : Binding m Read Write operation) : OperationKind := operation.kind

abbrev Authorized (m : Type → Type) := ExceptT (CallError Empty) m

/-- Policy and handler still share the typed input here; Route.ofHandler is the sole erasure. -/
def Binding.toRoute [Monad m] {operation : Operation kind Input Output Error}
    (binding : Binding m Read Write operation) (context : RequestContext)
    (cap : Capability m Read Write kind) : Route (Authorized m) :=
  Route.ofHandler operation fun input => ExceptT.mk do
    match ← binding.policy context (Capability.toRead cap) input with
    | .error error => pure (.error error)
    | .ok () => pure (.ok (← binding.handler context cap input))

structure PublicOperation where
  operation : OperationInfo
  http : HttpBinding
  metadata : PublicMetadata
  deriving Repr, BEq

/-- Calling approve is the explicit publication decision. No automatic discovery. -/
structure Export (m : Type → Type) where
  private mk ::
  http : HttpBinding
  metadata : PublicMetadata
  route : RequestContext → Route (Authorized m)

def Binding.approve [Monad m] {operation : Operation kind Input Output Error}
    (binding : Binding m Read Write operation)
    (provide : RequestContext → Capability m Read Write kind) : Export m :=
  ⟨binding.http, binding.metadata, fun context => binding.toRoute context (provide context)⟩

def Export.describe (exported : Export m) : PublicOperation :=
  ⟨(exported.route (.anonymous "")).info, exported.http, exported.metadata⟩

end LeanApp
