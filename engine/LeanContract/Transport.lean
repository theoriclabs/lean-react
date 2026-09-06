import LeanContract.Operation

namespace Contract
open Ontology

structure WireRequest where
  operation : OperationId
  kind : OperationKind
  input : WireValue

inductive WireResponse where
  | success (value : WireValue)
  | domainError (value : WireValue)

/-- Adapters handle host effects and status policy; the shared interpreter handles codecs. -/
structure Transport (m : Type → Type) where
  send : WireRequest → m (CallResult WireResponse Empty)

def Transport.interpreter [Monad m] (transport : Transport m) : Interpreter m where
  call operation input := do
    let response ← transport.send ⟨operation.identity, operation.kind, operation.inputCodec.encode input⟩
    pure <| match response with
    | .error error => .error (error.mapDomain Empty.elim)
    | .ok (.success value) => (operation.outputCodec.decode value).mapError CallError.decode
    | .ok (.domainError value) =>
      match operation.errorCodec.decode value with
      | .ok error => .error (.domain error)
      | .error errors => .error (.decode errors)

/-- Identity/kind and input are checked before the typed handler runs. -/
def serve [Monad m] (operation : Operation kind Input Output Error)
    (handler : Handler m operation) (request : WireRequest) : m (CallResult WireResponse Empty) := do
  if request.operation != operation.identity then
    return .error (.incompatible ⟨operation.identity, request.operation⟩)
  if request.kind != kind then
    return .error (.protocol ⟨"operation.kind_mismatch", none, ""⟩)
  match operation.inputCodec.decode request.input with
  | .error errors => return .error (.decode errors)
  | .ok input =>
    let result ← handler input
    return .ok <| match result with
      | .ok output => .success (operation.outputCodec.encode output)
      | .error error => .domainError (operation.errorCodec.encode error)

/-- Checked erasure for an explicit allowlist. No reflection-based global registration. -/
structure Route (m : Type → Type) where
  private mk ::
  info : OperationInfo
  invoke : WireRequest → m (CallResult WireResponse Empty)

def Route.ofHandler [Monad m] (operation : Operation kind Input Output Error)
    (handler : Handler m operation) : Route m :=
  ⟨operation.describe, serve operation handler⟩

structure Router (m : Type → Type) where
  private mk ::
  routes : List (Route m)

def Router.create (routes : List (Route m)) : Validation (Router m) := do
  let mut seen : List OperationId := []
  for route in routes do
    if seen.contains route.info.identity then
      throw (ValidationErrors.single "operation.duplicate_identity" []
        [("namespace", route.info.identity.namespaceName), ("name", route.info.identity.name),
         ("version", route.info.identity.version)])
    seen := route.info.identity :: seen
  pure ⟨routes⟩

def Router.manifest (router : Router m) : List OperationInfo := router.routes.map Route.info

def Router.transport [Monad m] (router : Router m) : Transport m where
  send request :=
    match router.routes.find? (fun route => route.info.identity == request.operation) with
    | some route => route.invoke request
    | none => pure (.error (.protocol ⟨"operation.not_found", none, ""⟩))

end Contract
