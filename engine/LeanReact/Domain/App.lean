import LeanReact.Domain.View
import LeanReact.Router
import LeanContract.Transport
import LeanApi.Core

/-! # Pages built from typed endpoints (DDD-LR-06)

```
def registerPage : Element :=
  form api.register
    (onSuccess := fun _ => navigate "/books")
    (onError := fun
      | .alreadyRegistered => fieldError "email" "This email already has an account.")

def borrowButton (book : Ref Book) : Action Unit :=
  call (api.borrow book)
    (onError := fun
      | .notFound    => notice "No such book."
      | .unavailable => notice "This book is on loan.")

def bookPage (book : Ref Book) : Element :=
  load (api.getBook book)
    (onError := fun | .notFound => DOM.p {} #[text "No such book."])
    fun page => bookView page (borrowButton book)

def app : App where
  api   := api
  pages := [ "/register" ==> registerPage, "/books/:book" ==> bookPage ]
```

* `form`, `call` and `load` take a typed `Endpoint I E O` (`api.register`, or `api.borrow book`
  with its path fields given), so `onError` handles exactly `E`. It is always required; an
  endpoint whose error type is `Empty` uses `(onError := nofun)`.
* A form has one editor per body field. Path fields are given (`api.borrow book`) or bound by
  name from the page route; the actor is never an editor.
* `call` is an ordinary `Action Unit` (a button's `onPress`), and `navigate` an ordinary action:
  both act on the mounted `App` (one per document, like the browser's location).
* A page's path parameters are its arguments, in path order (`"/books/:book" ==> bookPage`).
* `load` scopes its data by endpoint, given fields, signed-in actor and auth generation: a scope
  change drops the old value at once, and a late reply for an older scope never shows. A
  successful command run from the app reloads the page's data (DDD-LR-04). -/

namespace LeanReact.Domain
open LeanDb.Model LeanApi.Core Ontology

/-! ## The client as a wire transport -/

/-- The JSON-level operation with a given identity: codecs are the identity on wire values. -/
private def rawOperation (kind : Contract.OperationKind) (identity : Contract.OperationId) :
    Validation (Contract.Operation kind WireValue WireValue WireValue) :=
  let raw : Codec WireValue := ⟨.named ⟨"leanreact", "Json"⟩ "raw/1" .unit, id, .ok⟩
  Contract.Operation.create kind identity raw raw raw

private def frameworkOnly : Contract.CallError ε → Contract.CallError Empty
  | .domain _ => .protocol { code := "app.domain_as_framework" }
  | .unauthenticated => .unauthenticated
  | .forbidden => .forbidden
  | .transport value => .transport value
  | .protocol value => .protocol value
  | .decode value => .decode value
  | .incompatible value => .incompatible value
  | .cancelled => .cancelled

/-- A client as a monomorphic wire transport, so it can travel in a context (an `Interpreter`
quantifies over types). Each call is re-typed at its endpoint by the endpoint's codecs. -/
def wireTransport (client : Contract.Interpreter Action) : Contract.Transport Action where
  send request := do
    match rawOperation request.kind request.operation with
    | .error errors => pure (.error (.decode errors))
    | .ok operation =>
      pure <| match ← client.call operation request.input with
        | .ok value => .ok (.success value)
        | .error (.domain value) => .ok (.domainError value)
        | .error failure => .error (frameworkOnly failure)

/-! ## The mounted app -/

/-- What event handlers (`call`, `navigate`) act on: the mounted `App`. -/
structure AppRuntime where
  shell : ShellProps
  transport : Contract.Transport Action
  /-- Show a message that is not about one form field. -/
  notify : String → Action Unit
  /-- After a successful command: reload the page's data. -/
  invalidate : Action Unit

initialize appRuntimeCell : IO.Ref (Option AppRuntime) ← IO.mkRef none

/-- Install (or, with `none`, remove) the mounted app. Browser: an intrinsic. -/
def installAppRuntime (runtime : Option AppRuntime) : Action Unit := ⟨appRuntimeCell.set runtime⟩

/-- The mounted app, if any. Browser: an intrinsic. -/
def currentAppRuntime : Action (Option AppRuntime) := ⟨appRuntimeCell.get⟩

/-- What `App` provides to its pages while rendering. -/
structure AppContext where
  shell : Option ShellProps := none
  transport : Option (Contract.Transport Action) := none
  requestTransport : Option (ResourceRequest → Contract.Transport Action) := none
  /-- The signed-in profile, part of every page scope. -/
  actor : Option String := none
  /-- `:name` parameters of the matched page route, raw. -/
  params : List (String × String) := []
  /-- Successful commands so far; loads reload when it moves. -/
  commands : Nat := 0
  deriving TypeName

def appContext : Context AppContext := createContext "LeanReact.Domain.AppContext" {}

/-- Used outside an `App`: every call is refused as a framework failure, nothing navigates. -/
def detachedShell : Shell := {
  generation := 0
  currentGeneration := pure 0
  framework := fun _ => pure ()
  navigate := fun _ => pure ()
  refresh := pure ()
  client := ⟨fun _ _ => pure (.error (.protocol { code := "app.missing", detail := "rendered outside an App" }))⟩ }

/-- The page's shell: the app's callbacks and its client re-typed per call. -/
def AppContext.resolvedShell (app : AppContext) : Shell :=
  match app.shell, app.transport with
  | some props, some transport =>
    { toShellProps := props, client := transport.interpreter,
      requestClient := app.requestTransport.map fun factory request => (factory request).interpreter }
  | _, _ => detachedShell

/-- The JSON value of a raw route segment: references are bare integers. -/
def segmentJson (raw : String) : Lean.Json :=
  match JsonWire.decimalInt? raw with
  | some value => if toString value == raw then .num ⟨value, 0⟩ else .str raw
  | none => .str raw

/-- The endpoint's path fields: those it was given, then those bound by name from the route. -/
def endpointBindings (endpoint : Endpoint I E O) (params : List (String × String)) : Lean.Json :=
  .mkObj (endpoint.pathParams.filterMap fun name =>
    match endpoint.bound.lookup name with
    | some value => some (name, value)
    | none => (params.lookup name).map fun raw => (name, segmentJson raw))

/-- The path fields as scope text, e.g. `book=7` (portable; no JSON printer). -/
def bindingsText (wire : Lean.Json) : String :=
  match wire with
  | .obj fields => "&".intercalate (fields.toList.map fun (name, value) => name ++ "=" ++ pathText value)
  | _ => ""

/-- Go to `path` in the mounted app (an ordinary action, e.g. a form's `onSuccess`). -/
def navigate (path : String) : Action Unit := do
  if let some app ← currentAppRuntime then app.shell.navigate path

private def feedbackText [HasRecord I] (feedback : Feedback I) : String :=
  let fields := feedback.fields.map fun (field, message) =>
    (HasRecord.record (T := I)).fieldName field ++ ": " ++ message
  " ".intercalate (fields ++ feedback.message.toList)

/-! ## `form`, `call`, `load` -/

/-- A form over a typed endpoint: one editor per body field; path fields are given or bound
from the page route. -/
def endpointForm [HasRecord I] (endpoint : Endpoint I E O) (onSuccess : O → Action Unit)
    (onError : E → Feedback I) (label : String := "Submit") : Element :=
  let spec : FormSpec endpoint.kind I O E :=
    { operation := endpoint.operation.contract, onError, afterSuccess := onSuccess, label,
      establishesSession := endpoint.operation.metadata.establishesSession }
  let identity := endpoint.operation.contract.identity
  -- `stable:` keeps one component type per endpoint across renders (drafts survive a re-render).
  let view : Component Unit := Component.named ("stable:LeanReact.Domain.Form/" ++ identity.namespaceName ++ "/" ++ identity.name) <|
    LeanReact.component fun _ => do
      let app ← useContext appContext "domain.form.app"
      let model ← useDomainForm spec app.resolvedShell (endpointBindings endpoint app.params)
      pure (spec.render model)
  element view ()

/-- Run a typed endpoint from an event (`onPress`). Only path fields are sent, so this is for
endpoints whose other inputs are the actor. A domain error's message goes to the app's notice
region; a success runs `onSuccess`, then reloads the page's data. A reply for an older auth
generation is ignored. -/
def endpointCall [HasRecord I] (endpoint : Endpoint I E O) (onSuccess : O → Action Unit)
    (onError : E → Feedback I) : Action Unit := do
  let some app ← currentAppRuntime | pure ()
  let contract := endpoint.operation.contract
  match contract.inputCodec.decode (endpointBindings endpoint []) with
  | .error errors => app.shell.framework (.decode errors)
  | .ok input =>
    let result ← app.transport.interpreter.call contract input
    if (← app.shell.currentGeneration) != app.shell.generation then return
    match result with
    | .ok output =>
      if endpoint.operation.metadata.establishesSession then app.shell.authenticationChanged
      onSuccess output
      app.invalidate
    | .error (.domain error) =>
      let feedback := onError error
      app.notify (feedbackText feedback)
      if let some path := feedback.navigation then app.shell.navigate path
    | .error failure => app.shell.framework (frameworkOnly failure)

private def reportFailure (shell : Shell) (state : ResourceState O (Contract.CallError E)) : Action Unit :=
  match state with
  | .failure _ (.loader error) => match error with
    | .domain _ => pure ()
    | other => shell.framework (frameworkOnly other)
  | .failure _ (.call failure) => shell.framework failure.toCallError
  | .failure _ (.exception message) => shell.framework (.transport ⟨"resource.exception", message⟩)
  | _ => pure ()

/-- A page's data from a read-only endpoint. Scoped by endpoint, path fields, actor and auth
generation (and reloaded after each successful command): a scope change drops the old value
at once, and a late reply for an older scope never shows. -/
def endpointLoad [HasRecord I] (endpoint : Endpoint I E O) (onError : E → Element)
    (render : O → Element) : Element :=
  let contract := endpoint.operation.contract
  let identity := contract.identity
  let view : Component Unit := Component.named ("stable:LeanReact.Domain.Load/" ++ identity.namespaceName ++ "/" ++ identity.name) <|
    LeanReact.component fun _ => do
      let app ← useContext appContext "domain.load.app"
      let shell := app.resolvedShell
      let wire := endpointBindings endpoint app.params
      let input := contract.inputCodec.decode wire
      let scope := identity.namespaceName ++ "/" ++ identity.name ++ "/" ++ identity.version ++ "|" ++
        bindingsText wire ++ "|" ++ (app.actor.getD "-") ++ "|" ++ toString shell.generation
      let key := Key.inSpace "domain-load" (scope ++ "|" ++ toString app.commands)
      let resource ← useResource key (fun request =>
        match input with
        | .error errors => pure (.error (.decode errors))
        | .ok value => ((shell.requestClient.map (fun factory => factory request)).getD shell.client).call contract value)
        #[] input.isOk "domain.load"
      let token := match resource.state with
        | .loading token | .success token _ | .failure token _ => token
        | .idle => ⟨Key.string "idle", 0⟩
      let phase := match resource.state with
        | .idle => "idle" | .loading _ => "loading" | .success _ _ => "success" | .failure _ _ => "failure"
      useEffect #[.string key.value, .nat token.generation, .string phase] (do
        reportFailure shell resource.state
        pure (pure ())) "domain.load.failures"
      pure <| match input, resource.state with
        | .error _, _ => DOM.p { role := some "alert" } #[LeanReact.text "Invalid address."]
        | _, .success _ value => keyed (Key.inSpace "domain-load-view" scope) (render value)
        | _, .failure _ (.loader (.domain error)) => onError error
        | _, .failure _ _ => DOM.p { role := some "alert" } #[LeanReact.text "Unable to load. Try again."]
        | _, _ => DOM.p { role := some "status", ariaLive := some "polite" } #[LeanReact.text "Loading…"]
  element view ()

/-! ## Pages and the app -/

/-- A page's path parameter, decoded from its route segment with the type's wire codec. -/
class RouteParameter (α : Type) where
  parse : String → Option α

instance [Wire α] : RouteParameter α where
  parse raw := match (Wire.codec (α := α)).decode (segmentJson raw) with
    | .ok value => some value
    | .error _ => none

/-- What a page can be: an element, or a function of its path parameters, in path order. -/
class PageBody (P : Type) where
  build : P → List String → Option Element

instance : PageBody Element where
  build page arguments := if arguments.isEmpty then some page else none

instance [RouteParameter α] [PageBody P] : PageBody (α → P) where
  build page arguments := match arguments with
    | [] => none
    | raw :: rest => (RouteParameter.parse raw).bind fun value => PageBody.build (page value) rest

/-- One page of an `App`: a path template (`/books/:book`) and how to build its element. -/
structure PageRoute where
  path : String
  build : List (String × String) → Option Element

def PageRoute.of [PageBody P] (path : String) (page : P) : PageRoute :=
  ⟨path, fun params => PageBody.build page (params.map (·.2))⟩

infixr:60 " ==> " => PageRoute.of

/-- An application: its endpoints and its pages. -/
structure App where
  api : Api
  pages : List PageRoute

/-- `:name` segments of `template` against `path`, or `none` when they do not match. -/
def matchRoute (template path : String) : Option (List (String × String)) := do
  let expected := (Route.segments template).toList
  let actual := (Route.segments path).toList
  guard (expected.length == actual.length)
  (expected.zip actual).foldlM (fun acc (pattern, segment) =>
    match segmentParameter? pattern with
    | some name => some (acc ++ [(name, segment)])
    | none => if pattern == segment then some acc else none) []

/-- What the host supplies when mounting an `App`. -/
structure AppProps where
  shell : ShellProps
  /-- `pathname` (and optional `?search`) of the current location. -/
  location : String
  /-- The signed-in profile, if any; a change remounts the page and drops its data. -/
  actor : Option String := none

/-- Renders the first page whose path matches the location, under the app context, and a
polite status region for notices. Installs itself as the mounted app. The client is fixed
when the component is made, as for `screenComponent`. -/
def App.component (app : App) (client : Contract.Interpreter Action)
    (requestClient : Option (ResourceRequest → Contract.Interpreter Action) := none) : Component AppProps :=
  let transport := wireTransport client
  let requestTransport : Option (ResourceRequest → Contract.Transport Action) :=
    requestClient.map fun factory (request : ResourceRequest) => wireTransport (factory request)
  Component.named "LeanReact.Domain.App" <| LeanReact.component fun props => do
    let path := (Route.split props.location).1
    let pageKey := path ++ "|" ++ (props.actor.getD "-") ++ "|" ++ toString props.shell.generation
    let notice ← useState (none : Option (String × String)) "domain.app.notice"
    let commands ← useState (0 : Nat) "domain.app.commands"
    let invalidate := commands.modify (· + 1)
    let shell : ShellProps := { props.shell with refresh := invalidate }
    let notify : String → Action Unit := fun text => notice.set (some (pageKey, text))
    let runtime : AppRuntime := ⟨shell, transport, notify, invalidate⟩
    useEffect #[.string pageKey, .nat commands.value] (do
      installAppRuntime (some runtime)
      pure (installAppRuntime none)) "domain.app.install"
    let status := match notice.value with
      | some (key, text) => if key == pageKey then text else ""
      | none => ""
    let matched := app.pages.findSome? fun page =>
      (matchRoute page.path path).bind fun params => (page.build params).map (page.path, params, ·)
    pure <| match matched with
      | some (template, params, element) =>
        fragment #[
          provide appContext { shell := some shell, transport := some transport, requestTransport,
                               actor := props.actor, params, commands := commands.value }
            (keyed (Key.inSpace "domain-page" (template ++ "|" ++ pageKey)) element),
          DOM.p { role := some "status", ariaLive := some "polite" } #[LeanReact.text status]]
      | none => DOM.p { role := some "alert" } #[LeanReact.text "Page not found."]

end LeanReact.Domain
