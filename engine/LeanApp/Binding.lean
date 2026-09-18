import LeanApp.Context
import LeanApp.Capability

namespace LeanApp
open Contract Ontology

inductive HttpMethod where
  | post
  deriving Repr, BEq, DecidableEq

/-- Declarative per-principal limit on one operation; the host enforces it with a token bucket. -/
structure RateLimit where
  perPrincipalPerMinute : Nat
  burst : Nat := perPrincipalPerMinute / 6
  deriving Repr, BEq

structure HttpBinding where
  path : String
  method : HttpMethod := .post
  /-- Overrides the server's body limit for this path; enforced before the body is buffered. -/
  maxBodyBytes : Option Nat := none
  rateLimit : Option RateLimit := none
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
  if let some limit := http.maxBodyBytes then
    if limit == 0 || limit > 2^32 then Validation.fail "http.invalid_body_limit" [] [("path", http.path)]

/-- Gateway publication of a success reply: topic `"{topicPrefix}:{value.topicField}"`, and also
`"user:{value.alsoToActorField}"` when set. Domain errors are never published. -/
structure Publish where
  topicField : String
  topicPrefix : String
  eventName : String
  alsoToActorField : Option String := none
  deriving Repr, BEq

structure PublicMetadata where
  title : String := ""
  description : String := ""
  /-- The intended access rule as published, e.g. "role ≥ editor". Filled from the binding's rule. -/
  describePolicy : String := ""
  publish : Option Publish := none
  /-- The success value carries `{ticket, expiresAt, topics}` for the gateway's event stream. -/
  issuesStreamTicket : Bool := false
  deriving Repr, BEq

/-- Authority failures use Contract's error channel; domain errors stay in the handler. -/
abbrev Policy (m : Type → Type) (Read : Type → Type)
    (_ : Operation kind Input Output Error) :=
  RequestContext → ReadCapability m Read → Input → m (CallResult Unit Empty)

/-- A policy with its public description. `LeanApp.Policy` combinators build rules; a binding
spreads one in with `{ Policy.authenticated with … }`. Raw policy functions remain accepted. -/
structure Rule (m : Type → Type) (Read : Type → Type)
    (operation : Operation kind Input Output Error) where
  policy : Policy m Read operation
  describePolicy : String := ""

structure Binding (m : Type → Type) (Read Write : Type → Type)
    (operation : Operation kind Input Output Error) extends Rule m Read operation where
  handler : RequestContext → Capability m Read Write kind → Handler m operation
  http : HttpBinding
  metadata : PublicMetadata := {}

def Binding.executionKind (_ : Binding m Read Write operation) : OperationKind := operation.kind

/-- Published metadata: a rule's description replaces an empty `metadata.describePolicy`. -/
def Binding.publicMetadata (binding : Binding m Read Write operation) : PublicMetadata :=
  if binding.describePolicy.isEmpty then binding.metadata
  else { binding.metadata with describePolicy := binding.describePolicy }

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

def HttpBinding.toJson (http : HttpBinding) : Lean.Json :=
  .mkObj [("path", .str http.path), ("method", .str (match http.method with | .post => "POST")),
    ("maxBodyBytes", match http.maxBodyBytes with | some cap => Lean.toJson cap | none => .null)]

def Publish.toJson (publish : Publish) : Lean.Json :=
  .mkObj [("topicField", .str publish.topicField), ("topicPrefix", .str publish.topicPrefix),
    ("eventName", .str publish.eventName),
    ("alsoToActorField", match publish.alsoToActorField with | some field => .str field | none => .null)]

def PublicMetadata.toJson (metadata : PublicMetadata) : Lean.Json :=
  .mkObj [("title", .str metadata.title), ("description", .str metadata.description),
    ("describePolicy", .str metadata.describePolicy),
    ("publish", match metadata.publish with | some publish => publish.toJson | none => .null),
    ("issuesStreamTicket", .bool metadata.issuesStreamTicket)]

/-- One manifest entry: the operation description plus its HTTP binding and public metadata. -/
def PublicOperation.toJson (op : PublicOperation) : Lean.Json :=
  op.operation.toJson |>.setObjVal! "http" op.http.toJson |>.setObjVal! "metadata" op.metadata.toJson

/-- The `/api/manifest` body. Generated clients embed the same value to refuse a stale bundle. -/
def PublicOperation.manifest (operations : List PublicOperation) : Lean.Json :=
  .mkObj [("operations", .arr (operations.map PublicOperation.toJson).toArray)]

/-- Calling approve is the explicit publication decision. No automatic discovery. -/
structure Export (m : Type → Type) where
  private mk ::
  http : HttpBinding
  metadata : PublicMetadata
  route : RequestContext → Route (Authorized m)

def Export.of (http : HttpBinding) (metadata : PublicMetadata)
    (route : RequestContext → Route (Authorized m)) : Export m :=
  ⟨http, metadata, route⟩

def Binding.approve [Monad m] {operation : Operation kind Input Output Error}
    (binding : Binding m Read Write operation)
    (provide : RequestContext → Capability m Read Write kind) : Export m :=
  ⟨binding.http, binding.publicMetadata, fun context => binding.toRoute context (provide context)⟩

def Export.describe (exported : Export m) : PublicOperation :=
  ⟨(exported.route (.anonymous "")).info, exported.http, exported.metadata⟩

end LeanApp
