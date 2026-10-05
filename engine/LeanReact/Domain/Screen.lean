import LeanReact.Domain.View

namespace LeanReact.Domain
open LeanApp.Domain Ontology

structure ScreenProps (Actor : Type) where
  shell : ShellProps
  route : String
  actor : Option (Ref Actor)
  policyGeneration : Nat := 0

structure ScreenModel (I O E : Type) where
  resource : Resource O (Contract.CallError E)
  input : Validation I
  bound : Lean.Json
  scopeKey : Key

def useDomainScreen [HasRecord I] [RouteInput I] [HasTypeId A]
    (spec : ScreenSpec I O E) (client : Contract.Interpreter Action) (props : ScreenProps A)
    (requestClient : Option (ResourceRequest → Contract.Interpreter Action) := none) : Hook (ScreenModel I O E) := do
  let input := RouteInput.parse (Input := I) props.route
  let _ : HasTypeId (RouteInput.Target (Input := I)) := RouteInput.targetIdentity
  let key := match input with
    | .ok value => (ResourceScope.mk (RouteInput.reference value) props.actor
        props.shell.generation props.policyGeneration).key
    | .error _ => Key.inSpace "invalid-route" props.route
  let resource ← useResource key (fun request =>
    match input with
    | .error errors => pure (.error (.decode errors))
    | .ok value => ((requestClient.map (fun factory => factory request)).getD client).call spec.operation value) #[] input.isOk "domain.screen"
  let bound := match input with | .ok value => spec.operation.inputCodec.encode value | .error _ => .mkObj []
  pure ⟨resource, input, bound, key⟩

private def frameFailure [HasRecord I] (spec : ScreenSpec I O E) (shell : Shell)
    (state : ResourceState O (Contract.CallError E)) : Action Unit := do
  match state with
  | .failure _ (.loader (.domain error)) =>
    if let some path := (spec.onError error).navigation then shell.navigate path
  | .failure _ (.loader error) => match error with
    | .domain _ => pure ()
    | .unauthenticated => shell.framework .unauthenticated
    | .forbidden => shell.framework .forbidden
    | .transport value => shell.framework (.transport value)
    | .protocol value => shell.framework (.protocol value)
    | .decode value => shell.framework (.decode value)
    | .incompatible value => shell.framework (.incompatible value)
    | .cancelled => shell.framework .cancelled
  | .failure _ (.call failure) => shell.framework failure.toCallError
  | .failure _ (.exception message) => shell.framework (.transport ⟨"resource.exception", message⟩)
  | _ => pure ()

private def actionComponent (action : SomeAction) (client : Contract.Interpreter Action)
    (requestClient : Option (ResourceRequest → Contract.Interpreter Action)) : Component (ShellProps × Lean.Json) :=
  let _ : HasRecord action.Input := action.record
  LeanReact.component fun (context, bound) => do
    let shell : Shell := { toShellProps := context, client, requestClient }
    let model ← useDomainForm action.spec shell bound
    pure (action.spec.render model)

/-- Stable action components are prepared outside the render closure. Scope-keyed mounts discard drafts
and protected state on actor/resource changes; refresh retains the current actor's edited drafts. -/
def ScreenSpec.component [HasRecord I] [RouteInput I] [HasTypeId A]
    (spec : ScreenSpec I O E) (client : Contract.Interpreter Action)
    (requestClient : Option (ResourceRequest → Contract.Interpreter Action) := none) : Component (ScreenProps A) :=
  let controls := spec.actions.toArray.map fun (action : SomeAction) =>
    let _ : HasRecord action.Input := action.record
    (Key.inSpace action.spec.operation.identity.namespaceName action.spec.operation.identity.name, actionComponent action client requestClient)
  LeanReact.component fun props => do
    let shell : Shell := { toShellProps := props.shell, client, requestClient }
    let model ← useDomainScreen spec client props requestClient
    let token := match model.resource.state with
      | .loading token | .success token _ | .failure token _ => token
      | .idle => ⟨Key.string "idle", 0⟩
    let status := match model.resource.state with
      | .idle => "idle" | .loading _ => "loading" | .success _ _ => "success" | .failure _ _ => "failure"
    useEffect #[.string model.scopeKey.value, .nat token.generation, .string status] (do
      frameFailure spec shell model.resource.state
      pure (pure ())) "domain.screen.failures"
    let body := match model.input, model.resource.state with
      | .error _, _ => DOM.p { role := some "alert" } #[LeanReact.text "Invalid address."]
      | _, .success _ value => spec.view value
      | _, .failure _ (.loader (.domain error)) => DOM.p { role := some "alert" }
          #[LeanReact.text ((spec.onError error).message.getD "")]
      | _, .failure _ _ => DOM.p { role := some "alert" } #[LeanReact.text "Unable to load. Try again."]
      | _, _ => DOM.p { role := some "status", ariaLive := some "polite" } #[LeanReact.text "Loading…"]
    let shell := { props.shell with refresh := model.resource.refresh }
    let actions := if model.input.isOk then keyedEach controls Prod.fst fun (_, control) =>
      keyed (Key.inSpace model.scopeKey.value control.name) (element control (shell, model.bound)) else empty
    pure (fragment #[body, actions])
end LeanReact.Domain
