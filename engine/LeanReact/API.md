# LeanReact source API

[LeanApp documentation](../../docs/README.md) · [LeanReact guide](../../docs/LEANREACT.md)

`import LeanReact` exposes buildable Lean 4.33 definitions for `Component Props`, `Hook α`, `Action α`, typed elements/events, state, context, forms, resources, and managed effects. Native reference implementations and the integrated engine/LeanJS/React adapter are tested. See [INTRINSICS.md](../runtime/INTRINSICS.md) and the [implemented scope](../../docs/IMPLEMENTED.md).

`useCell initial site` provides an immediate local `Cell α`. Its `read` action reads the current value, and `modifyGet transition` applies a pure `α → β × α` transition and returns the result. Cells persist per mount without scheduling a render. They are suitable for a local service interpreter that must process multiple calls before React commits; ordinary `useState` remains the UI state primitive.

Components consume ordinary props. Callbacks have types such as `α → Action Unit`; slots have types such as `α → Element`. `element` defers child rendering and establishes a separate hook boundary. Custom hooks are ordinary functions returning `Hook α`. Rendering can construct and compose actions without running them. Simple components need neither event enums nor effect rows.

The following complete program is also checked as [tests/runtime/Examples.lean](../../tests/runtime/Examples.lean):

```lean
import LeanReact

open LeanReact

namespace LeanReactExamples

structure CounterModel where
  count : Nat
  increment : Action Unit

def useCounter (initial : Nat) : Hook CounterModel := do
  let count ← useState initial (site := "count")
  pure { count := count.value, increment := count.modify (· + 1) }

def Counter : Component Unit := component fun _ => do
  let model ← useCounter 0
  pure <| DOM.button { onPress := some model.increment }
    #[text s!"Count: {model.count}"]

def CounterPanel : Component Nat := component fun initial => do
  let model ← useCounter initial
  pure <| DOM.div { className := some "counter-panel" } #[
    DOM.h2 {} #[text s!"Total {model.count}"],
    DOM.button { onPress := some model.increment } #[text "Add one"]
  ]

structure ListProps (α : Type) where
  items : Array α
  key : α → Key
  row : α → Element
  empty : Element := text "Nothing here yet"

def ListView (α : Type) : Component (ListProps α) := component fun props =>
  pure <| if props.items.isEmpty then props.empty
    else keyedEach props.items props.key props.row

structure CardProps where
  title : String
  onOpen : String → Action Unit
  footer : String → Element := fun _ => empty

def Card : Component CardProps := component fun props =>
  pure <| DOM.article {} #[
    DOM.h2 {} #[text props.title],
    props.footer props.title,
    DOM.button { onPress := some (props.onOpen props.title) } #[text "Open"]
  ]

def cards (names : Array String) (openCard : String → Action Unit) : Element :=
  element (ListView String) {
    items := names
    key := Key.string
    row := fun name => element Card {
      title := name
      onOpen := openCard
      footer := fun title => DOM.span {} #[text s!"About {title}"]
    }
  }

structure PickerProps where
  selected : Bool
  onChange : Bool → Action Unit

def Picker : Component PickerProps := component fun props =>
  pure <| DOM.input {
    type := .checkbox
    checked := some props.selected
    ariaLabel := some "Selected"
    onChange := some fun event => props.onChange event.checked
  }

def LocalPicker : Component Unit := component fun _ => do
  let selection ← useState false (site := "selection")
  pure <| element Picker { selected := selection.value, onChange := selection.set }

structure SignupProps where
  submit : String → Action Unit

-- A form never navigates; blur validates; Ctrl+S keeps the browser's save dialog closed.
def Signup : Component SignupProps := component fun props => do
  let email ← useState "" (site := "email")
  let error ← useState "" (site := "error")
  pure <| DOM.form { onSubmit := props.submit email.value } #[
    DOM.label { htmlFor := "signup-email" } #[text "Email"],
    DOM.input {
      id := some "signup-email"
      type := .email
      value := some email.value
      autoComplete := some "email"
      ariaDescribedBy := some "signup-error"
      data := #[("testid", "signup-email")]
      onChange := some fun event => email.set event.value
      onBlur := some fun event => error.set (if event.value.isEmpty then "Email is required." else "")
      onKeyDown := some fun event =>
        if event.ctrl && event.key == "s" then pure .preventDefault else pure .continue
    },
    DOM.p { id := some "signup-error", role := some "alert" } #[text error.value],
    DOM.button { type := .submit } #[text "Sign up"]
  ]

structure Theme where
  label : String
  deriving TypeName

def theme : Context Theme := createContext "LeanReactExamples.theme" { label := "Default" }

def ThemeLabel : Component Unit := component fun _ => do
  let current ← useContext theme (site := "theme")
  pure <| text current.label

def themed : Element := element (provider theme) {
  value := { label := "Scoped" }
  children := fragment #[element ThemeLabel (), element Counter ()]
}

-- A host adapter supplies this function. Setup and cleanup are both deferred actions.
structure SubscriptionProps where
  topic : String
  subscribe : String → Action (Action Unit)

def Subscription : Component SubscriptionProps := component fun props => do
  useEffect #[.string props.topic] (props.subscribe props.topic) (site := "subscription")
  pure <| text s!"Subscribed to {props.topic}"

end LeanReactExamples
```

## Implemented surface

| API | Semantics |
| --- | --- |
| `component`, `Component.named`, `element` | Construct/reuse a typed component definition, give it a diagnostic name, and create a deferred child. |
| `text`, `empty`, `fragment`, `node` | Function-based tree construction. `node` is the explicit low-level tag/attribute escape hatch; the typed `DOM` helpers below cover ordinary application screens. |
| `keyed`, `keyedEach`, `Key.string`, `Key.nat`, `Key.inSpace` | Stable sibling identity. `Key.inSpace` length-prefixes the namespace; `keyedEach` diagnoses duplicate keys in both renderers. |
| `Hook.pure`, `Hook.bind`, `Hook.map` | `do` notation and reusable hook composition. |
| `Action.pure`, `Action.bind`, `Action.map` | Deferred action composition; state setters and supplied service callbacks return Actions. |
| `useState initial (site := label)` | A render snapshot with `value`, `set`, `modify`, and `read`. `modify` uses React functional updates; updater functions must be pure. |
| `createContext name default`, `useContext`, `provide`, `provider` | Typed context values, scoped provider trees, and a provider Component. |
| `useEffect deps setup (site := label)` | Register an Action returning an Action for cleanup. Setup executes at commit, never at construction/render. |
| `validateHookTrace` | Executable comparison of native hook traces, returning `Except String Unit`. This is not a static checker. |

Effect dependencies are `Array Dependency`, with `.string`, `.nat`, `.int`, and `.bool` constructors. Keep the dependency count fixed. Use a semantic version/key dependency for function-bearing service records; closures and arbitrary records are not automatically dependency-comparable. Return `pure () : Action Unit` when cleanup has nothing to do. The JS bridge additionally supports asynchronous host setup and cleanup. Typed service failures can be ordinary `Except` results within Action.

`State.value` is a render snapshot. `State.read` is an Action returning the latest committed React value; it does not force queued updates to commit. The native cell updates immediately, so it can be inspected without a renderer. Prefer `modify` when a new value depends on existing state. Functions may be stored as state values.

`createContext` requires `[TypeName α]` solely for native typed environment lookup. Concrete records can `deriving TypeName`, including records containing callbacks. Consumers and providers need no TypeName parameter because the Context captures its native pack/unpack functions. Context names must be globally unique, stable declaration names, used consistently at one type and with one default. The browser adapter erases this native packing machinery explicitly.

## DOM helpers and events

`DOM.Props` provides optional `id`, `className`, `title`, `role`, `tabIndex : Option Int`, `hidden`, the ARIA strings `ariaLabel`, `ariaDescribedBy`, `ariaLabelledBy`, `ariaLive`, the ARIA booleans `ariaExpanded`, `ariaSelected`, `ariaPressed`, `ariaDisabled`, `data : Array (String × String)` (rendered as `data-<key>`), `style : Array (StyleProp × String)`, and the handlers `onClick`, `onKeyDown`, `onKeyUp`, `onFocus`, `onBlur`, `onMouseEnter`, `onMouseLeave`, `onScroll`. `StyleProp` is a closed enum of React's camelCase property names, so a misspelled property is a compile error while values remain strings.

| Helper | Props | Notes |
| --- | --- | --- |
| `div span p h1`–`h6 «section» article nav header footer main aside ul li strong em code pre kbd summary table thead tbody tr` | `Props` | Props then an Array of children. |
| `th td` | `CellProps` | Adds `colSpan`, `rowSpan`, `scope`. |
| `dialog details` | `DisclosureProps` | Adds `«open»`. |
| `img` | `ImgProps` | Requires `src` and `alt`; optional `width`/`height`. |
| `button` | `ButtonProps` | `disabled`, `type` (`.button` default, `.submit`, `.reset`), `autoFocus`, `onPress : Option (Action Unit)`; `onPress` takes precedence over `onClick`. |
| `input` | `InputProps` | `type` (`.text .email .password .search .checkbox .number .url .tel .date .time .range .radio`), `value`/`defaultValue`, `checked`/`defaultChecked`, `min`/`max`/`step` strings, `onChange`, plus the shared field props. |
| `textarea` | `TextAreaProps` | `value`/`defaultValue`, `rows`, `cols`, `onChange`, plus the shared field props. |
| `select` | `SelectProps` | `value`/`defaultValue`, `name`, `disabled`, `required`, `autoFocus`, `onChange` (the option `value`); children are `«option»` elements. |
| `«option»` | `OptionProps` | Required `value`, `disabled`. |
| `form` | `FormProps` | `onSubmit : Action Unit := pure ()`, `name`, `autoComplete`, `noValidate`. The browser's submit default is **always** prevented, so Enter in a field or a `.submit` button runs the action without navigating; use `node "form"` for native submission. |
| `label` | `LabelProps` | `htmlFor`. |
| `a` | `AnchorProps` | `href`, `target`, `rel`. |

`FieldProps`, shared by `input` and `textarea`, adds `name`, `placeholder`, `disabled`, `readOnly`, `required`, `autoFocus`, `autoComplete`, `spellCheck`, `maxLength`, `onInput`, and `onPaste`.

`PressEvent` contains `alt`, `ctrl`, `metaKey`, `shift`; `onMouseEnter`/`onMouseLeave` reuse it. `ChangeEvent` contains `value : String` and `checked : Bool`. `KeyEvent` contains `key : String`, the modifier fields, and `«repeat»`. `FocusEvent` contains the control's current `value` (`""` elsewhere), which makes blur validation a one-liner. `InputEvent` contains `value` and `isComposing` for IME-safe live text. `PasteEvent` contains `text` and `html : Option String`, copied from `clipboardData` during dispatch. `ScrollEvent` contains `scrollTop` and `scrollLeft`. The browser snapshots these values before calling the Lean callback, including before async work. The raw mutable browser event is not passed through. Input props permit controlled and uncontrolled use; applications should consistently select one mode. This is a small typed DOM subset, not a complete schema or an accessibility checker.

`onKeyDown` handlers return `Action KeyOutcome`, where `KeyOutcome` is `.continue` or `.preventDefault`. Only a synchronous result can prevent the browser default; decide before awaiting host work (an asynchronous `.preventDefault` is reported through `onActionError`). The native reference records the outcome through `Reference.dispatchKeyDown`. **Migration:** existing `KeyEvent → Action Unit` handlers keep type-checking, because `Unit`, `Action Unit` and `KeyEvent → Action Unit` coerce to their `KeyOutcome` forms meaning `.continue`; `DOM.onKeyDown' handler` is the explicit spelling. A `do` block that ends in an `if` without `else` needs a final `pure .continue`.

Accessibility: roles alone are not enough. Pair inputs with `label`/`htmlFor` or `ariaLabel`, link error text through `ariaDescribedBy`, announce status with `role := some "status"` or `ariaLive`, keep custom controls reachable with `tabIndex`, and give `img` a meaningful `alt`. The helpers make these attributes typed; they do not check them.

Native tests can inspect and drive a rendered form: `Reference.RenderedTree.byId?`, `byTag?`, `byTestId?` and `findNode?` return a node's recorded attributes, `Reference.attribute?` reads a string attribute, and `Reference.dispatchPress/Change/Input/Paste/Focus/Blur/KeyUp/Submit` run the matching handlers; `dispatchKeyDown` returns the recorded `KeyOutcome`.

## Foreign components with imperative handles

`foreign (name : String) (props : ForeignProps P H) : Element` mounts a host React component registered under `name` and gives Lean a typed imperative handle:

```lean
structure Handle (ops : Type) where
  ops : ops                      -- a record of Actions, each returning HandleResult α
  alive : Action Bool

structure ForeignProps (P H : Type) where
  props : P
  onReady : Handle H → Action Unit          -- once per mount, after the first commit
  onGone : Action Unit := pure ()           -- on unmount, before a remount's onReady
  reference : ForeignReference P H := {}    -- native stand-in: render and stub ops

inductive HandleResult (α : Type) | ok (value : α) | unmounted
```

The **typed result** is the chosen unmount policy: in the browser every operation checks the mount flag before touching the React ref and resolves to `.unmounted` afterwards, so a handle retained in a `Cell` never reaches a stale node and React logs no warning; no host error is thrown and `Action.catchError` is not involved. `alive` reports the same flag. A keyed remount fires the old instance's `onGone`, then `onReady` with a fresh handle. Store handles in `useCell`, not `useState`, and match on `HandleResult` at the call site. Handle operations are Actions and therefore cannot run during render.

The host side registers `registerForeign(name, { component, props, ops })` once (see [INTRINSICS.md](../runtime/INTRINSICS.md#imperative-handles)). The native reference renders `reference.render props` under a `.child name` boundary and, on `commit`, calls `onReady` with a handle over the caller-supplied `reference.ops` stubs; disposing flips `alive` and runs `onGone`. Stubs run as given, so `.unmounted` is enforced only by the browser runtime. Without stubs the reference never calls `onReady`. The worked example is the canvas sparkline in `examples/lean/Examples/Sparkline.lean` with `examples/adapters/example-sparkline.mjs`.

## Router

Applications define their own route type and a total codec; the router keeps `pathname + search` in sync with it.

```lean
structure RouteCodec (ρ : Type) where
  parse : String → Option ρ     -- pathname + search; none renders the notFound route
  print : ρ → String

structure Router (ρ : Type) where
  current : ρ
  location : String             -- the raw pathname + search
  codec : RouteCodec ρ
  navigate : ρ → Action Unit    -- pushState; a no-op when already there
  replace : ρ → Action Unit     -- replaceState
  back : Action Unit
```

`useRouter codec notFound site : Hook (Router ρ)` owns a history subscription. The usual shape is one `element routerProvider { children }` near the root and `useRoute codec notFound site` in the screens below it; the provider shares one concrete `RouteState` context (`location` plus the history actions), so no per-application context or `TypeName` registration is needed and every consumer picks its route type through its codec. `router.link to props children` renders `DOM.a` with `href := codec.print to` whose unmodified primary clicks navigate in place; modified clicks, `target`ed anchors, and other origins keep the browser default, and external URLs are ordinary `DOM.a` anchors. `Router.href` prints a route.

Codecs work on strings, and portable Lean has no string splitting yet, so `Route.split location` (`(pathname, search)`), `Route.segments path` (non-empty decoded segments), `Route.nat? segment`, `Query.parse search : Array (String × String)`, `Query.encode pairs` and the portable `Route.join segments` are provided; in the browser they are host intrinsics with these Lean definitions as the reference. Routing is same-origin only; the browser adapter rejects paths that do not start with `/`. There is no nested routing, loader, or code splitting.

Natively, `RenderEnv` carries an in-memory `History`; `Reference.runHook`/`render` accept `(history := some h)` so a test can `navigate`, re-render, `back`, and inspect `h.entries`. `Reference.dispatchNavigate` stands for a link click. See [tests/runtime/Router.lean](../../tests/runtime/Router.lean) and the two-screen example in `examples/lean/Examples/Routing.lean` (served under `/router/`).

## Reference execution and limits

`Reference.runHook` prepares a Hook, yielding its value, primitive trace, and queued effects. `Reference.render` expands an Element into a `RenderedTree` for inspection and event lookup. Each child has its own recorded trace. Native context providers correctly scope typed values around descendant rendering. `Reference.runAction` explicitly executes an Action. Calling `prepared.commit` runs pending setups and returns an idempotent cleanup Action; partially failed setup cleans up already acquired resources. See [Reference.lean tests](../../tests/runtime/Reference.lean).

This native model is a **single-render reference interpreter**. `useState` allocates a fresh typed IO cell on each invocation; `Reference.render` does not reconcile mounted identities or schedule rerenders. Every explicit reference commit runs its queued effects; it does not compare dependencies across renders. React supplies persistent mounted state, batching, key reconciliation, and dependency-sensitive lifecycle behavior. Native `Action.ofIO` and `Action.catchError` are reference/host facilities, not portable browser IO imports.

Forms and resources are included below. LeanJS also checks fixed primitive-hook sequences through reachable components and named custom hooks, rejecting inconsistent branches, unsupported repetition and dynamic site labels. See the [compiler hook checks](../../tests/compiler/Hooks.lean). Keep hook calls unconditional, label state/effect/context sites, and render stateful repeated rows through child components. The JS runtime compares committed traces and checks the compiler-produced `hookPlan` as an additional guard. Hoist component definitions and stable generic factory results outside render so their identities survive rerenders.

There is no source view-syntax macro, `@[react]` annotation, nested router, or foreign-component source generator. SSR has a tested example workload, not general SSR/hydration qualification. See the [implemented scope and limits](../../docs/IMPLEMENTED.md).

Verification: `sh tests/runtime/check-lean.sh` compiles the library and this complete example, asserts five invalid programs do not type-check, and runs executable reference checks. `node --test tests/runtime/*.test.mjs` tests the independent ESM bridge with real React roots in jsdom. `npm test` additionally checks the compiler and mounts generated Lean components in the [integration suite](../../tests/integration/). `npm run test:browser` runs the separate real-browser suite; jsdom alone does not establish browser compatibility.


## P06: parser-driven drafts and composable editors

Importing `LeanReact` now also imports `LeanReact.Forms` and `LeanReact.Resources`. Forms use the existing `Ontology.Lens` and `Ontology.Validation` APIs. Their implementation is ordinary Lean over the P03 state/action primitives; no form rule or Tickets parser is reimplemented in JavaScript.

`DraftParser Raw Value` contains `parse : Raw → Validation Value` and `format : Value → Raw`. `Draft Raw Value` contains the exact raw value plus the separate parsed result. `Draft.create`/`replace` reparse without replacing invalid text with a valid fallback. Formatting is explicit; it never runs automatically on each edit. Caller-supplied format/parse and map/inverse functions are not assumed to have proven round-trip laws.

Parser combinators are `identity`, `ofExcept`, `map`, `checked`, `atPath`, `product`, `optional`, and `list`. `ofExcept` adapts an existing typed domain parser by mapping its error to structured ValidationErrors. `product` accumulates independent errors; `checked` sequences a dependent check. Optional raw input is `Option Raw`: `none` is valid absence and `some invalidRaw` remains invalid presence. List parsing uses `Array Raw`, accumulates all invalid item errors, and prefixes paths with their indices.

`FieldBinding Raw` is an ordinary record of `value`, `set : Raw → Action Unit`, and `modify : (Raw → Raw) → Action Unit`. `FieldBinding.ofState` adapts P03 state. `binding.map forward backward` changes a complete field representation; `binding.focus lens` preserves surrounding data by modifying the latest owner value through the lens. Two focused edits therefore preserve each other's sibling changes. `binding.draft parser` parses the current field snapshot.

`binding.present` yields an optional child binding. Retained child callbacks become no-ops after the optional owner is cleared. `binding.item keyOf key` finds a list child by stable key; its updates follow reorder and become no-ops after removal. Keys must be unique and should remain immutable while editing. Use a lens to edit an item's contents without changing its identity. These bindings have render snapshots, so their `value` is not mutated by an action.

`Editor Raw` is just `Component (FieldBinding Raw)`. `Editor.map` adapts the props for another editor. `Editor.optional editor initial layout` gives a supplied layout `{present, child, enable, clear}`; enabling an already-present value retains it. `Editor.list keyOf row layout` passes each row its binding and removal Action, and passes the overall layout keyed children plus an append callback. All markup, controls, and generated IDs remain the caller's choice. Hoist editor factory results like other component definitions.

`useForm parser initial site` returns `Form Raw Value` with `draft`, `binding`, `read`, and `reset`. It owns one raw state cell and can be reused from any layout. `form.validate` parses current input at action time; `form.submit onValid` returns `Action (Validation α)` and only calls `onValid : Value → Action α` after successful validation. Invalid raw input remains unchanged. A caller still decides how to display errors and callback results. There is no dirty/touched policy or implicit reset on prop changes. An explicit reset restores the initial value captured by that rendered reset Action; use a keyed component or explicit replacement for identity changes.

Form reads use P03 `State.read`: in React they see the latest committed raw state. A `set` followed immediately by `submit` in the same action does not flush React's queued update. Submit from the following committed event/render, or validate the explicitly available new raw value directly. Parser and initial-value changes do not silently overwrite drafts; retain stable parsers or explicitly manage such changes.

The following complete source uses the actual Tickets domain parser and is checked as `tests/runtime/P06Examples.lean`. It demonstrates two layouts over one hook, focused fields, open editor combinators, and typed resource states:

```lean
import LeanReact
import Examples.Tickets.Domain

open LeanReact Ontology Examples.Tickets

namespace P06Examples

-- Reuse the actual Tickets parser. Only its errors are adapted to structured validation.
def titleParser : DraftParser String Title := DraftParser.ofExcept Title.parse Title.value fun error =>
  match error with
  | .empty => ValidationErrors.single "ticket.title.empty"
  | .tooLong length => ValidationErrors.single "ticket.title.tooLong" [] [("length", toString length)]

def TextField : Editor String := component fun field => pure <| DOM.input {
  value := some field.value
  onChange := some fun event => field.set event.value
}

structure EditProps where
  initial : String
  save : Title → Action Unit

structure EditModel where
  form : Form String Title
  submit : Action Unit

def useTitleEditor (props : EditProps) : Hook EditModel := do
  let form ← useForm titleParser props.initial "ticket-title"
  pure { form, submit := do let _ ← form.submit props.save; pure () }

def Compact : Component EditProps := component fun props => do
  let editor ← useTitleEditor props
  pure <| DOM.div {} #[
    element TextField editor.form.binding,
    DOM.button { onPress := some editor.submit } #[text "Save"]
  ]

def Page : Component EditProps := component fun props => do
  let editor ← useTitleEditor props
  let notice := match editor.form.draft.parsed with
    | .ok title => text s!"Ready: {title.value}"
    | .error errors => text errors.first.code
  pure <| DOM.section {} #[
    DOM.h2 {} #[text "Edit ticket"], element TextField editor.form.binding, notice,
    DOM.button { onPress := some editor.submit } #[text "Save"],
    DOM.button { onPress := some editor.form.reset } #[text "Reset"]
  ]

def titleLens : Lens (String × Bool) String := Lens.field ⟨"example", "Draft"⟩ "title"
  Prod.fst (fun draft title => (title, draft.2))

def Composite : Component Unit := component fun _ => do
  let parser := titleParser.product (DraftParser.identity : DraftParser Bool Bool)
  let form ← useForm parser ("", false) "composite"
  pure <| element TextField (form.binding.focus titleLens)

def OptionalText : Editor (Option String) := Editor.optional TextField "" fun model =>
  DOM.div {} #[model.child,
    DOM.button { onPress := some model.enable } #[text "Enable"],
    DOM.button { onPress := some model.clear } #[text "Clear"]]

def textRows (newId : Action String) : Editor (Array (String × String)) := Editor.list
  (fun row => Key.string row.1)
  (fun row remove => DOM.div {} #[
    element TextField (row.focus (Lens.field ⟨"example", "Row"⟩ "text" Prod.snd (fun old value => (old.1, value)))),
    DOM.button { onPress := some remove } #[text "Remove"]])
  (fun rows append => DOM.div {} #[rows,
    DOM.button { onPress := some (do let id ← newId; append (id, "")) } #[text "Append"]])

structure TicketResourceProps where
  scope : String
  revision : Nat
  load : ResourceRequest → Action (Except SaveError (Array TicketSummary))

def TicketResource : Component TicketResourceProps := component fun props => do
  let result ← useResource (Key.inSpace "tickets" props.scope) props.load
    #[.nat props.revision] true "ticket-resource"
  let content := match result.state with
    | .idle => text "Idle"
    | .loading _ => text "Loading"
    | .success _ tickets => text s!"{tickets.size} tickets"
    | .failure _ (.loader .notFound) => text "Missing"
    | .failure _ (.loader (.conflict _)) => text "Changed on the server"
    | .failure _ (.call failure) => text failure.code
    | .failure _ (.exception message) => text message
  pure <| DOM.div {} #[content,
    DOM.button { onPress := some result.refresh } #[text "Refresh"]]

end P06Examples
```

## P06: resources

`useResource key loader dependencies enabled site` returns a `Hook (Resource Value Error)` where `loader : ResourceRequest → Action (Except Error Value)`. A stable Key plus a fixed-length Array of Dependency values defines request scope. `enabled := false` keeps the resource idle. Loader closure identity is not a dependency; refresh uses the latest committed loader. Include all restart-worthy inputs in the key or explicit dependencies.

`ResourceState Value Error` has `.idle`, `.loading token`, `.success token value`, and `.failure token reason`. `ResourceToken` has `key` and an exact natural `generation`. Failure reasons distinguish `.loader error` (the original typed domain error), `.call failure` (a transport failure the host bridge recognised, as the portable `Contract.CallFailure`), and `.exception message` (any other host throw or rejected promise).

`Contract.CallFailure` is closed: `unauthenticated`, `forbidden`, `incompatible expected received`, `decode code`, `protocol code`, `transport code`, `cancelled`, with `CallFailure.code`, `.kind`, and `.toCallError`. `Resource.failureAs : ResourceFailure ε → Except CallFailure ε` collapses the three shapes into the loader's typed error or a call failure (`.exception message` becomes `.transport message`). This helper was chosen over routing transport failures into the loader error type: loaders keep returning plain `Except Error Value`, existing `.loader` matches stay valid, and one function per component decides how each transport case renders. In the browser, `createRuntime({ onCallFailure })` (or the adapter's `configureRuntime`) additionally observes every recognised failure once, so an application can redirect on `unauthenticated` in one place. Host loaders built with `resourceLoader` from `engine/LeanContract/Service.mjs` forward the resource's AbortSignal to `fetch`.

A Resource exposes `state`, `refresh : Action Unit`, and `read : Action (ResourceState Value Error)`. In the browser, refresh starts a new generation and returns without waiting for completion. `read` observes the controller state immediately; rendering catches up through React. Every completion is checked against active ownership, token, and scope. Dependency/key changes, disable, refresh, and unmount suppress stale results; they also clear the prior result. Refresh after unmount or while disabled does nothing.

`ResourceRequest` exposes its `token`, `cancelled : Action Bool`, and `onCleanup : Action Unit → Action Unit`. Register cleanup after acquiring a resource. It runs once on replacement/unmount, or immediately if registered after cancellation. Host loaders additionally receive an AbortSignal. Cleanup callbacks run in reverse registration order, and host cleanup errors are reported separately through `onCleanupError`. Cancellation is cooperative: work that ignores it may continue, but its result cannot replace the current resource state.

Native `useResource` has a sequential reference implementation: preparation does not load; explicit commit starts the loader; explicit refresh runs it again; cleanup invalidates ownership. Each invocation is fresh, with no native mounted reconciliation or automatic dependency scheduling. Pure `ResourceTracker.begin`, `.settle`, and `.cancel` allow deterministic testing of reordered results. The browser scheduler is in `engine/runtime/resources.mjs`; [INTRINSICS.md](../runtime/INTRINSICS.md#p06-forms-and-resource-integration) specifies the exact seven-slot LeanJS boundary, including both erased type arguments. Parent adapter wiring and generated-code integration remain separate work.

P06 does not add a shared resource cache, request deduplication, retry policy, Suspense, form auto-deriving, schema-driven widgets, asynchronous field validation, or automatic draft merge policies. Ordinary callbacks/services and components remain the extension points.
