import LeanOntology

namespace Contract
open Ontology

inductive OperationKind where
  | query
  | command
  deriving Repr, BEq, DecidableEq

structure OperationId where
  namespaceName : String
  name : String
  version : String
  deriving Repr, BEq, DecidableEq

def OperationId.validate (identity : OperationId) : Validation Unit := do
  if identity.namespaceName.isEmpty || identity.name.isEmpty || identity.version.isEmpty then
    Validation.fail "operation.empty_identity"

/-- All type and kind indices survive until the adapter's checked wire boundary. -/
structure Operation (kind : OperationKind) (Input Output Error : Type) where
  private mk ::
  identity : OperationId
  inputCodec : Codec Input
  outputCodec : Codec Output
  errorCodec : Codec Error

namespace Operation

def create (kind : OperationKind) (identity : OperationId)
    (input : Codec Input) (output : Codec Output) (error : Codec Error) :
    Validation (Operation kind Input Output Error) := do
  identity.validate
  pure ⟨identity, input, output, error⟩

def canonical (kind : OperationKind) (identity : OperationId)
    [Wire Input] [Wire Output] [Wire Error] : Validation (Operation kind Input Output Error) :=
  create kind identity Wire.codec Wire.codec Wire.codec

def kind (_ : Operation k Input Output Error) : OperationKind := k

end Operation

structure OperationInfo where
  identity : OperationId
  kind : OperationKind
  input : WireSchema
  output : WireSchema
  error : WireSchema
  deriving Repr, BEq

def Operation.describe (operation : Operation k Input Output Error) : OperationInfo :=
  ⟨operation.identity, k, operation.inputCodec.schema, operation.outputCodec.schema, operation.errorCodec.schema⟩

def OperationInfo.toJson (info : OperationInfo) : Lean.Json :=
  .mkObj [("namespace", .str info.identity.namespaceName), ("name", .str info.identity.name),
    ("version", .str info.identity.version),
    ("kind", .str (match info.kind with | .query => "query" | .command => "command")),
    ("input", info.input.toJson), ("output", info.output.toJson), ("error", info.error.toJson)]

structure TransportError where
  code : String
  detail : String := ""
  deriving Repr, BEq, DecidableEq

structure ProtocolError where
  code : String
  status : Option Nat := none
  detail : String := ""
  deriving Repr, BEq, DecidableEq

structure ContractMismatch where
  expected : OperationId
  received : OperationId
  deriving Repr, BEq, DecidableEq

inductive CallError (DomainError : Type) where
  | domain (error : DomainError)
  | unauthenticated
  | forbidden
  | transport (error : TransportError)
  | protocol (error : ProtocolError)
  | decode (errors : DecodeErrors)
  | incompatible (details : ContractMismatch)
  | cancelled
  deriving Repr, BEq, DecidableEq

def CallError.mapDomain (f : ε → δ) : CallError ε → CallError δ
  | .domain error => .domain (f error)
  | .unauthenticated => .unauthenticated
  | .forbidden => .forbidden
  | .transport error => .transport error
  | .protocol error => .protocol error
  | .decode errors => .decode errors
  | .incompatible details => .incompatible details
  | .cancelled => .cancelled

abbrev CallResult (Output Error : Type) := Except (CallError Error) Output
abbrev DomainResult (Output Error : Type) := Except Error Output

/-- A handler remains a function in the chosen host monad. -/
abbrev Handler (m : Type → Type) (_ : Operation kind Input Output Error) :=
  Input → m (DomainResult Output Error)

/-- Application services should usually be smaller records of selected functions. -/
structure Interpreter (m : Type → Type) where
  call : {kind : OperationKind} → {Input Output Error : Type} →
    Operation kind Input Output Error → Input → m (CallResult Output Error)

end Contract
