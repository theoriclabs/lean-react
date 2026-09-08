import LeanApp.Module

namespace LeanApp
open Contract Ontology

structure Application (m : Type → Type) where
  private mk ::
  name : String
  metadata : PublicMetadata
  modules : List (Module m)

/-- Validate before exposing a listener. Dependencies are presence requirements, not init order. -/
def Application.create (name : String) (modules : List (Module m))
    (metadata : PublicMetadata := {}) : Validation (Application m) := do
  if name.isEmpty then Validation.fail "application.empty_name"
  let mut names : List String := []
  for mod in modules do
    if mod.name.isEmpty then Validation.fail "module.empty_name"
    if names.contains mod.name then
      Validation.fail "module.duplicate_name" [] [("module", mod.name)]
    names := mod.name :: names
  let mut paths : List HttpBinding := []
  let mut storage : List StorageOwnership := []
  let exports := modules.flatMap Module.exports
  let _ ← Router.create (exports.map (fun e => e.route (.anonymous "")))
  for mod in modules do
    for dep in mod.dependencies do
      if !names.contains dep then
        Validation.fail "module.missing_dependency" [] [("module", mod.name), ("dependency", dep)]
    for exported in mod.exports do
      exported.http.validate
      if paths.contains exported.http then
        Validation.fail "http.ambiguous_path" [] [("path", exported.http.path)]
      paths := exported.http :: paths
    for claim in mod.storage do
      if claim.physicalTable.isEmpty || claim.mappingId.isEmpty then
        Validation.fail "storage.empty_identity"
      if storage.any (fun prior => prior.physicalTable == claim.physicalTable &&
          prior.mappingId != claim.mappingId) then
        Validation.fail "storage.mapping_collision" [] [("table", claim.physicalTable)]
      storage := claim :: storage
  pure ⟨name, metadata, modules⟩

def Application.manifest (app : Application m) : List PublicOperation :=
  (app.modules.flatMap Module.exports).map Export.describe

/-- Existing wire protocol and codecs, with the outer authority channel flattened. -/
def Application.transport [Monad m] (app : Application m) (context : RequestContext) : Transport m where
  send request := do
    match Router.create ((app.modules.flatMap Module.exports).map (fun e => e.route context)) with
    | .error _ => pure (.error (.protocol ⟨"application.invalid_registry", none, ""⟩))
    | .ok router =>
      match ← (router.transport.send request).run with
      | .error error => pure (.error error)
      | .ok result => pure result

/-- HTTP adapters can select an approved identity from metadata then use the shared transport.
Require both the URL and wire identity to match, so one endpoint cannot invoke another export. -/
def Application.dispatchHttp [Monad m] (app : Application m) (context : RequestContext)
    (http : HttpBinding) (request : WireRequest) : m (CallResult WireResponse Empty) :=
  match app.manifest.find? (fun info => info.http == http) with
  | none => pure (.error (.protocol ⟨"http.not_found", none, ""⟩))
  | some info =>
    if info.operation.identity != request.operation then
      pure (.error (.incompatible ⟨info.operation.identity, request.operation⟩))
    else (app.transport context).send request

end LeanApp
