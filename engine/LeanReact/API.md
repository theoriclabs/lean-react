# LeanReact source API (P03/P06)

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
| `text`, `empty`, `fragment`, `node` | Function-based tree construction. `node` is the explicit low-level tag/attribute escape hatch. |
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

`DOM.Props` provides optional `id`, `className`, `title`, `role`, `ariaLabel`, `onClick`, and `onKeyDown`. Ordinary helpers are `div`, `span`, `p`, `h1`, `h2`, `section` (escaped as `«section»` in its declaration), `article`, `ul`, and `li`; they accept props then an Array of children.

`DOM.button` accepts `ButtonProps`, adding `disabled`, typed `type` (`.button`, `.submit`, `.reset`), and `onPress : Option (Action Unit)`. Its default type is `.button`; `onPress` takes precedence if both click forms are supplied. `DOM.input` accepts `InputProps`, adding typed input kind, optional `value`/`defaultValue`, optional `checked`/`defaultChecked`, `placeholder`, `disabled`, `readOnly`, and `onChange`. `DOM.label` takes `LabelProps` with `htmlFor`; `DOM.a` takes `AnchorProps` with `href`.

`PressEvent` contains `alt`, `ctrl`, `metaKey`, `shift`. `ChangeEvent` contains `value : String` and `checked : Bool`. `KeyEvent` contains `key : String` and the same modifier fields. The browser snapshots these values before calling the Lean callback, including before async work. The raw mutable browser event is not passed through. Input props permit controlled and uncontrolled use; applications should consistently select one mode. This is a small typed DOM subset, not a complete schema or an accessibility checker.

## Reference execution and limits

`Reference.runHook` prepares a Hook, yielding its value, primitive trace, and queued effects. `Reference.render` expands an Element into a `RenderedTree` for inspection and event lookup. Each child has its own recorded trace. Native context providers correctly scope typed values around descendant rendering. `Reference.runAction` explicitly executes an Action. Calling `prepared.commit` runs pending setups and returns an idempotent cleanup Action; partially failed setup cleans up already acquired resources. See [Reference.lean tests](../../tests/runtime/Reference.lean).

This native model is a **single-render reference interpreter**. `useState` allocates a fresh typed IO cell on each invocation; `Reference.render` does not reconcile mounted identities or schedule rerenders. Every explicit reference commit runs its queued effects; it does not compare dependencies across renders. React supplies persistent mounted state, batching, key reconciliation, and dependency-sensitive lifecycle behavior. Native `Action.ofIO` and `Action.catchError` are reference/host facilities, not portable browser IO imports.

P03 did not include forms or resources; the additive P06 APIs below now supply them. There is still no source syntax macro, `@[react]` annotation, compiler static hook-placement checker, router, SSR/hydration qualification, or foreign-component source generator. Keep hook calls unconditional, label state/effect/context sites, and render stateful repeated rows through child components. The JS runtime compares committed traces and accepts a compiler-produced `hookPlan`; it cannot prove all control-flow paths safe. Hoist component definitions and stable generic factory results outside render; the parent must preserve their identity in compiled output.

Verification: `sh tests/runtime/check-lean.sh` compiles the library and this complete example, asserts five invalid programs do not type-check, and runs executable reference checks. `node --test tests/runtime/*.test.mjs` tests the independent ESM bridge with real React roots in jsdom. No generated-Lean React mounting is claimed until the parent connects the intrinsic ABI.


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
    | .failure _ (.exception message) => text message
  pure <| DOM.div {} #[content,
    DOM.button { onPress := some result.refresh } #[text "Refresh"]]

end P06Examples
```

## P06: resources

`useResource key loader dependencies enabled site` returns a `Hook (Resource Value Error)` where `loader : ResourceRequest → Action (Except Error Value)`. A stable Key plus a fixed-length Array of Dependency values defines request scope. `enabled := false` keeps the resource idle. Loader closure identity is not a dependency; refresh uses the latest committed loader. Include all restart-worthy inputs in the key or explicit dependencies.

`ResourceState Value Error` has `.idle`, `.loading token`, `.success token value`, and `.failure token reason`. `ResourceToken` has `key` and an exact natural `generation`. Failure reasons distinguish `.loader error` (the original typed domain error) from `.exception message` (a host throw or rejected promise).

A Resource exposes `state`, `refresh : Action Unit`, and `read : Action (ResourceState Value Error)`. In the browser, refresh starts a new generation and returns without waiting for completion. `read` observes the controller state immediately; rendering catches up through React. Every completion is checked against active ownership, token, and scope. Dependency/key changes, disable, refresh, and unmount suppress stale results; they also clear the prior result. Refresh after unmount or while disabled does nothing.

`ResourceRequest` exposes its `token`, `cancelled : Action Bool`, and `onCleanup : Action Unit → Action Unit`. Register cleanup after acquiring a resource. It runs once on replacement/unmount, or immediately if registered after cancellation. Host loaders additionally receive an AbortSignal. Cleanup callbacks run in reverse registration order, and host cleanup errors are reported separately through `onCleanupError`. Cancellation is cooperative: work that ignores it may continue, but its result cannot replace the current resource state.

Native `useResource` has a sequential reference implementation: preparation does not load; explicit commit starts the loader; explicit refresh runs it again; cleanup invalidates ownership. Each invocation is fresh, with no native mounted reconciliation or automatic dependency scheduling. Pure `ResourceTracker.begin`, `.settle`, and `.cancel` allow deterministic testing of reordered results. The browser scheduler is in `engine/runtime/resources.mjs`; [INTRINSICS.md](../runtime/INTRINSICS.md#p06-forms-and-resource-integration) specifies the exact seven-slot LeanJS boundary, including both erased type arguments. Parent adapter wiring and generated-code integration remain separate work.

P06 does not add a shared resource cache, request deduplication, retry policy, Suspense, form auto-deriving, schema-driven widgets, asynchronous field validation, or automatic draft merge policies. Ordinary callbacks/services and components remain the extension points.
