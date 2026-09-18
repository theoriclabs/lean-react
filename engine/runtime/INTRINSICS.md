# LeanReact intrinsic integration contract

P03 provides `createRuntime(React)` in `react.mjs` and `createIntrinsicAdapter(runtime, abi)` in `intrinsics.mjs`. The latter describes the semantic bridge. The integrated LeanJS ABI implementation is [`engine/adapters/leanjs-react.mjs`](../adapters/leanjs-react.mjs), registered by the reusable [`LeanReact.Compiler`](../LeanReact/Compiler.lean) module. Applications supply their output-relative module path. Generated-component, browser, and native-browser tests verify it. Historical P03 handoff requirements below describe that boundary; [implemented scope](../../docs/IMPLEMENTED.md) records its current status.

## Immediate local cells

The additional `Cell α` handle is opaque to LeanJS. Register `LeanReact.useCell` with arity 3 (`type, initial, site`), `LeanReact.Cell.read` with arity 2 (`type, cell`), and `LeanReact.Cell.modifyGet` with arity 4 (`valueType, resultType, cell, transition`). The two type slots are null. A transition returns `Prod.mk [result, nextValue]`. Host transitions execute synchronously, reject nested action execution, and update the cell before returning. `useCell` is a fixed hook primitive with kind `cell` and site argument 2. The local Tickets service uses it so batched saves observe current revisions.

The functions below list logical, explicit arguments after integration has handled type/proof erasure, dictionaries, default arguments, currying, and the compiler's calling convention. They do not prescribe the compiler's raw arities or constructor layout. In particular, `createContext` has a native `TypeName` dictionary that the browser registration must deliberately discard. Never let the compiler descend into the native IO/Dynamic reference implementations as a fallback for an unregistered intrinsic.

## Required `abi` object

All methods are synchronous except work explicitly wrapped as an Action. The adapter validates the required methods on creation.

| Method | Required behavior |
| --- | --- |
| `call(fn, args)` | Apply an encoded Lean closure using the actual backend convention; keep captured values and higher-order arguments intact. |
| `closure(arity, hostFn)` | Encode a host closure as a Lean callable. `hostFn` accepts ordinary positional arguments; its arguments/results otherwise retain backend values. |
| `record(typeName, fields)` | Encode a record using the compiler's actual field layout. See the three field contracts below. |
| `string(value)` | Decode a Lean String to a JS string. |
| `array(value)` | Decode a Lean Array to a JS array without serializing or recursively cloning its elements. |
| `key(value)` | Decode `LeanReact.Key` to its string value, preserving its complete namespace. |
| `dependencies(value)` | Decode `Array Dependency` to fixed-length JS dependencies with stable `Object.is` equality. Preserve the variant identity and exact Nat/Int values. For example, tagged strings such as `nat:123` and `string:123` are distinct. Allocating a new object per dependency on every render would be incorrect. |
| `attribute(value)` | Decode an Attribute to the **host** union described below. Leave its encoded handler closure intact. |
| `unit()` | Return the compiler representation of Lean Unit. Never assume this is JS `undefined`. |
| `componentIdentity(render)` | Return a stable, non-null token for the same immutable component render closure. Distinct captured factory instances must have distinct tokens. The bridge caches component types by this token. |
| `providerProps(value)` | Decode `ProviderProps` to `{value, children}` without cloning the value or child. Required when using `provider`; optional if only `provide` is used. |

`record` receives one of these logical field sets:

- `LeanReact.State`: `{value, set, modify, read}`. `value` is already a backend value; `set` and `modify` have already been wrapped with `abi.closure`; `read` is an opaque Action handle. Encode the record layout, not these values again.
- `LeanReact.PressEvent`: `{alt, ctrl, metaKey, shift}`. These are host booleans: encode them as backend Bool values.
- `LeanReact.ChangeEvent`: `{value, checked}` with a host string and boolean. `LeanReact.KeyEvent`: `{key, alt, ctrl, metaKey, shift, repeat}` with a host string and booleans. Encode each primitive before constructing the backend record.
- `LeanReact.FocusEvent`: `{value}` (host string, `""` for elements without a value). `LeanReact.InputEvent`: `{value, isComposing}`. `LeanReact.PasteEvent`: `{text, html}` where `html` is a host string or `null` (encode as `Option String`). `LeanReact.ScrollEvent`: `{scrollTop, scrollLeft}` as host integers (encode as `Int`).

`attribute` produces exactly one of:

```js
{ kind: "string", name: "className", value: "card" }
{ kind: "bool", name: "disabled", value: false }
{ kind: "press", handler: encodedLeanClosure }
{ kind: "change", handler: encodedLeanClosure }
{ kind: "keyDown", handler: encodedLeanClosure }        // handler returns Action KeyOutcome
{ kind: "keyUp" | "focus" | "blur" | "input" | "paste" | "mouseEnter" | "mouseLeave" | "scroll", handler: encodedLeanClosure }
{ kind: "submit", action: encodedAction }               // Action Unit; the runtime always prevents the default first
{ kind: "style", entries: [["backgroundColor", "red"], ...] }  // React camelCase names, string values
{ kind: "navigate", action: encodedAction }             // router link click; see Router below
```

`keyDown` handlers return `Action KeyOutcome`. The adapter additionally requires `keyOutcome(encoded)`, decoding `LeanReact.KeyOutcome` to the host string `"preventDefault"` or `"continue"`; the runtime calls `preventDefault()` only for a **synchronous** `"preventDefault"` result and reports an asynchronous one through `onActionError`, because the browser default cannot be prevented after the event has dispatched. `mouseEnter`/`mouseLeave` receive `PressEvent` modifier payloads.

This is a host protocol defined by P03; it is **not** a guess about the compiler's constructor encoding. Unknown variants should fail decoding.

The integrated adapter (`leanjs-react.mjs`) maps the Lean `Attribute` constructors directly: `LeanReact.Attribute.keyDown` (fields `[handler]`) through `LeanReact.Attribute.style` (fields `[Array (String × String)]`), with `LeanReact.KeyEvent.mk` fields `[key, alt, ctrl, metaKey, shift, repeat]`, `LeanReact.FocusEvent.mk [value]`, `LeanReact.InputEvent.mk [value, isComposing]`, `LeanReact.PasteEvent.mk [text, Option html]`, `LeanReact.ScrollEvent.mk [scrollTop, scrollLeft]` and `LeanReact.KeyOutcome.continue | preventDefault`. DOM helpers such as `DOM.form`, `DOM.textarea`, `DOM.select` and `Props.attributes` are ordinary compiled Lean; only `LeanReact.node` crosses the boundary, so no arity changes were needed for the added surface.

## Required intrinsic declarations

`Action`, `Hook`, `Element`, `Component`, and `Context` values crossing these functions are opaque host handles. Application props, state values, callback arguments, and slot parameters otherwise stay encoded Lean values. The compiler must not project fields from these opaque handles using its ordinary record representation. `State`, DOM props, Key, Dependency, and event records use ordinary backend records/constructors and the explicit codecs above.

| Lean declaration | Logical arguments | Host result / behavior |
| --- | --- | --- |
| `LeanReact.Action.pure` | `value` | Deferred Action returning the value. |
| `LeanReact.Action.bind` | `first, next` | Deferred sequencing, including Promise results from host services. |
| `LeanReact.Action.map` | `f, work` | Deferred map. |
| `LeanReact.Hook.pure` | `value` | Synchronous Hook returning the value. |
| `LeanReact.Hook.bind` | `first, next` | Hook sequencing within the current component. |
| `LeanReact.Hook.map` | `f, work` | Hook map. |
| `LeanReact.component` | `render` | A stable React component type from the supplied identity token. |
| `LeanReact.Component.named` | `name, component` | The same component type with a diagnostic display name. |
| `LeanReact.element` | `component, props` | React element; never invokes the child render inline. |
| `LeanReact.text` | `string` | React text node. |
| `LeanReact.empty` | none | Empty React child. |
| `LeanReact.fragment` | `children` | React Fragment. |
| `LeanReact.keyed` | `key, child` | Keyed Fragment around a child. |
| `LeanReact.keyedEach` | `items, keyOf, row` | Sibling keys checked for duplicates; row closures retain their captures. |
| `LeanReact.node` | `tag, attributes, children` | React DOM element with event adaptation. |
| `LeanReact.useState` | `initial, site` | Hook returning an encoded State record. Function values are never mistaken for initializers. |
| `LeanReact.useEffect` | `dependencies, setup, site` | Hook scheduling a setup Action returning a cleanup Action. |
| `LeanReact.createContext` | `name, defaultValue` | Stable typed context handle, cached by its globally unique declared name. |
| `LeanReact.useContext` | `context, site` | Hook reading the nearest matching provider or default. |
| `LeanReact.provide` | `context, value, child` | Scoped React provider element. |
| `LeanReact.provider` | `context` | Stable component consuming encoded ProviderProps. |
| `LeanReact.foreign` | `name, foreignProps` | Host component with a typed imperative handle; see [Imperative handles](#imperative-handles). |
| `LeanReact.useLocation` | `site` | Hook subscribing to the history; see [Router](#router). |
| `LeanReact.Route.split/segments/nat?`, `LeanReact.Query.parse/encode` | `string` / `pairs` | URL helpers; see [Router](#router). |

The source instances are `LeanReact.Action.instMonad` and `LeanReact.Hook.instMonad`. Ensure their generated dictionaries reference the intrinsic pure/bind functions, including derived Applicative/Functor methods. If compiler inlining occurs before intrinsic recognition, register the appropriate lowered definitions or prevent native reference code from being inlined across this boundary. Document the actual decision in the integrating adapter.

DOM helpers, props-to-attribute functions, Key constructors, application components, custom hooks, and ordinary domain functions should compile normally until reaching the listed boundaries. Default `site` arguments arrive as Lean strings (usually `""`); they are not optional arguments in the logical intrinsic handlers.

`Action.ofIO`, `Action.runIO`, `Hook.ofRender`, `Hook.runRender`, `Hook.mark`, Context packing functions, Element's native renderer, and the `Reference` namespace are **native reference operations**. They are not browser capabilities. Source `Action.catchError` currently handles native `IO.Error`; it has no binding until the parent supplies an explicit error conversion. Portable services can return typed `Except` values inside Action. The host runtime separately exports `catchAction` for JavaScript errors.

## Imperative handles

`LeanReact.foreign {P H : Type} (name : String) (props : ForeignProps P H) : Element` is registered with **arity 4**: `foreign(null, null, nameString, encodedForeignProps)`. `LeanReact.ForeignProps.mk` has fields `[props, onReady, onGone, reference]` (the two type parameters are omitted); the host ignores `reference`, which is the native stand-in. `LeanReact.Handle.mk` has fields `[ops, alive]`; `LeanReact.HandleResult.ok` has `[value]` and `LeanReact.HandleResult.unmounted` has `[]`.

The integrated adapter resolves `name` through a registry filled by the application before the first render:

```js
import { registerForeign, ctor } from '../../engine/adapters/leanjs-react.mjs';
registerForeign('sparkline', {
  component: SparklineCanvas,                 // React component using React.useImperativeHandle(ref, ...)
  props: value => ({ width: Number(value.fields[0]), ... }),   // Lean props record → React props
  ops: invoke => ctor('Examples.Sparkline.SparklineOps.mk', [  // Lean ops record of Actions
    points => invoke('draw', [points.map(Number)], count => BigInt(count)),
    invoke('clear'),                          // encode defaults to Lean Unit
  ]),
});
```

`invoke(method, args, encode)` returns an Action resolving to `HandleResult`: `.ok (encode result)` while mounted, `.unmounted` afterwards without touching the ref; a method returning a Promise resolves the Action asynchronously. Unknown methods throw a `TypeError` through the ordinary action error path. An unregistered name throws at first render with the name in the message.

The runtime building block is `runtime.handleElement(Component, props, { onReady, onGone, adapt }, children)`: a `HandleHost` owns the React ref and a mount flag, calls `onReady(adapt(invoke, alive))` from a once-per-mount effect after the first commit, and `onGone` from its cleanup, so a keyed remount fires `onGone` before the new `onReady`. Under Strict Mode's development double-invocation the pairs stay balanced.

## Router

`LeanReact.useLocation (site : String := "") : Hook RouteState` is the one router hook primitive: **arity 1**, kind `router`, site argument 0, registered in `LeanReact.Compiler.options.hooks`. The host returns `LeanReact.RouteState.mk` with fields `[locationString, navigateClosure, replaceClosure, backAction]`; `navigate`/`replace` take a same-origin path starting with `/` and resolve to Lean Unit, `back` is an Action. `useRouter`, `routerProvider`, `useRoute`, `Router.ofState`, and `Router.link` are ordinary compiled Lean over that primitive and the `LeanReact.RouteState` context, whose native `TypeName` dictionary is registered as the erased intrinsic `LeanReact.instTypeNameRouteState` (arity 0).

`engine/runtime/router.mjs` supplies `createRouterHooks(React, runtime, { history })`, `createBrowserHistory(window)` (`pathname + search`, `pushState`/`replaceState`/`back`, notifications for `popstate` and for its own pushes) and `createMemoryHistory(initial)` for tests and server rendering. The integrated adapter exports `router`; call `router.setHistory(createMemoryHistory('/path'))` before the first render to replace the lazily created browser history. `navigate` to the current location adds no entry.

URL helpers are intrinsics because portable Lean has no string splitting yet; their Lean bodies are the reference: `LeanReact.Route.split` (`String → String × String`, arity 1, `Prod.mk [pathname, search]` without `?`/hash), `LeanReact.Route.segments` (`String → Array String`, non-empty percent-decoded parts), `LeanReact.Route.nat?` (`String → Option Nat`, decimal only), `LeanReact.Query.parse` (`String → Array (String × String)`, `URLSearchParams` order and decoding), `LeanReact.Query.encode` (`Array (String × String) → String`, `application/x-www-form-urlencoded`). `LeanReact.Route.join` is portable Lean.

`LeanReact.Attribute.navigate` (fields `[action]`) maps to `runtime.onNavigate(action)`: an unmodified primary click on a same-origin anchor without a `target` prevents the browser navigation and runs the action; every other click keeps the default. The intrinsic adapter's attribute union gains `{ kind: "navigate", action }`.

## Identity, hooks, and lifecycle integration

The compiler must preserve the distinction between a component definition and a render-function prop. Hoist or memoize stable component definitions and generic family instances; do not reconstruct their React function type on every render. `componentIdentity` cannot just be a declaration name if a factory can produce distinct captured render closures. New component definitions during render are diagnosed by the host runtime. Existing cached definitions and context providers can be reused during render.

Context names must be globally unique, stable declaration names. The source/native environment and the intrinsic cache intentionally use those names as identity. Do not reuse one name at another type or with another default.

There is no static hook-placement checker in P03. The runtime records primitive `{kind, site}` entries per component and compares them with the last committed trace. A wrapper can additionally pass `hookPlan` to `runtime.component(render, {name, hookPlan})`; `validateHookTrace` is separately exported. A parent/compiler wrapper may generate plans and file/line labels. Custom hooks compose into the calling component's trace; child elements get independent traces. Runtime `namedHook(name, work)` adds a scope prefix.

Required compiler follow-up: analyze component/custom-hook control flow, label primitive sites, reject conditional/looped hooks unless all paths have the same provable sequence, and diagnose unknown higher-order Hook execution at the call site. State-bearing rows belong in child components. The dynamic trace catches observed count/kind/order changes and labeled same-kind swaps. It cannot prove all branches safe, see branches that never run, or distinguish swapped same-kind hooks without labels. Its optional plan is an interface for validation, not evidence that static analysis exists.

Actions execute only at host event/effect boundaries or explicit `runAction` calls. The runtime rejects attempts to execute an action during render or a state updater. State updater functions must remain pure because React may replay them. `State.read` returns the latest **committed** value in React; queued updates are applied by React, so chaining `modify` and `read` does not flush a render.

Effects require fixed-length dependency arrays and cleanup Actions (`pureAction(unit)` for a no-op cleanup). Setup runs after commit; cleanup runs on dependency changes/unmount. Async setup is supported by the JS runtime: if it resolves after disposal, its cleanup runs immediately. This disposes acquired resources but does not itself cancel pending work or suppress stale application replies. Host services must provide cancellation/request ownership when needed. Async action/effect errors go to the configured `onActionError`; this callback is a host error handler, not a React ErrorBoundary.

## Integration acceptance still owned by the parent

1. Implement the ABI object and intrinsic registration using `engine/LeanJS/ABI.md` and actual declaration metadata.
2. Compile the checked Lean examples, rather than substituting handwritten JS components.
3. Mount a generated counter and generic keyed list; verify captured callbacks/slots, state preservation, typed context, effect cleanup, and hook diagnostics through generated code.
4. Provide explicit typed wrappers for any foreign React component or host service. `runtime.foreignElement` and `hostAction(execute, encode)` are host building blocks; P03 introduces no arbitrary-JS source escape hatch.

The adapter test uses a deliberately test-only encoding and actual React mounting to exercise this protocol. It proves the codec boundary works, not that LeanJS uses that encoding.

# P06: forms and resource integration

P06 was implemented after reading `engine/LeanJS/ABI.md` (v0, pure LCNF with retained erased argument slots) and the current parent adapter. **Only `LeanReact.useResource` introduces a new required intrinsic.** `useForm`, parsers, drafts, field bindings, editor combinators, and form submission are ordinary Lean functions composing existing Hook/Action/useState intrinsics. No JavaScript copy of Tickets parsing or form validation is supplied.

## Exact new intrinsic signature

The following signature and constructor types were checked directly with Lean 4.33:

```lean
LeanReact.useResource {Value Error : Type}
  (key : LeanReact.Key)
  (loader : LeanReact.ResourceRequest → LeanReact.Action (Except Error Value))
  (dependencies : Array LeanReact.Dependency := #[])
  (enabled : Bool := true)
  (site : String := "") : LeanReact.Hook (LeanReact.Resource Value Error)
```

Register **arity 7**. Under the documented LeanJS ABI the imported host function receives:

```js
useResource(null, null, encodedKey, encodedLoader, encodedDependencies, encodedBool, siteString)
//          Value Error
```

Default arguments are elaborated at the Lean call site; they still occupy their slots. The two types have no content but their slots remain. No TypeName dictionary is involved. `loader` is a unary callable closure after any enclosing generic parameters have already been applied.

`engine/runtime/resources.mjs` exports:

```js
createResourceHooks(React, runtime, { onCleanupError } = {})
// -> { useResource(keyString, load, dependencies = [], enabled = true, site = "") }

createResourceIntrinsic(runtime, resources, abi)
// -> logicalUseResource(encodedKey, encodedLoader, encodedDependencies, encodedBool, siteString)
```

The parent can initialize the extension once beside its existing runtime and supply a full-slot wrapper:

```js
const resources = createResourceHooks(React, runtime);
const resourceIntrinsic = createResourceIntrinsic(runtime, resources, resourceABI);
export const useResource = (_Value, _Error, key, loader, dependencies, enabled, site) =>
  resourceIntrinsic(key, loader, dependencies, enabled, site);
```

This code describes the parent's pending integration; no files in `adapters/` or `engine/LeanJS/` were changed. The only P03 runtime change is `runtime.primitiveHook(kind, site, execute)`, an explicit host-extension boundary. The resource extension uses one `{kind:"resource", site}` trace entry around its fixed internal React hook sequence. Native reference traces use the same entry.

## Resource host protocol and required codecs

`resourceABI` is separate from P03's codec object. It requires these methods:

| Method | Contract |
| --- | --- |
| `key(encoded)` | Return the exact Key string. |
| `string(encoded)` | Return the site string. |
| `dependencies(encoded)` | Decode fixed-length dependencies with stable Object.is equality; retain variant distinctions and exact integers. |
| `bool(encoded)` | Decode the tagged Lean Bool to a host boolean. |
| `call(fn, args)` | Apply the actual LeanJS closure convention. |
| `request(hostRequest)` | Encode ResourceRequest, adapting its cancellation and cleanup callbacks as described below. |
| `result(encodedExcept)` | Decode `Except Error Value` into `{ok:true,value}` or `{ok:false,error}`. Preserve the contained backend value/error. |
| `state(hostState)` | Encode a ResourceState and its token/failure wrapper. Preserve the contained backend value/error. |
| `resource(fields)` | Construct the Resource record from `{state,refresh,read}`. All three fields have already been adapted; do not wrap read/refresh again. |
| `unit()` | Produce encoded Lean Unit. |

The host state union is:

```js
{ status: "idle" }
{ status: "loading", token: { key: "tickets", generation: 1n } }
{ status: "success", token, value: encodedValue }
{ status: "failure", token, error: { kind: "loader", error: encodedError } }
{ status: "failure", token, error: { kind: "exception", message: "host error text" } }
```

The host request is `{token, signal, cancelled, onCleanup}`. `signal` is an AbortSignal for direct host loaders; it is not a Lean record field. `cancelled` is an Action returning a host boolean, so the request codec must map its result to the tagged Lean Bool. `onCleanup` takes one opaque cleanup Action and returns an Action whose result must be mapped to Lean Unit. The Lean callback field has arity 1. The source can cooperate through `cancelled` and `onCleanup`; a specific foreign service adapter may retain the corresponding AbortSignal in its own host mapping.

The resource intrinsic already maps `refresh`'s result to `unit()`, `read`'s result through `state`, and each render snapshot through `state` before calling `resource`. It decodes loader results only at action time, after synchronous or asynchronous completion. It never serializes callback captures or domain payloads.

## Exact LeanJS record and constructor layout

The current ABI omits constructor parameters from `fields`, while constructor *functions* receive their erased parameter slots. These declarations have no erased proof fields in their payloads:

| Constructor | Full constructor-function arity / leading erased slots | `fields` in the resulting tagged constructor |
| --- | --- | --- |
| `LeanReact.ResourceToken.mk` | 2 / none | `[encodedKey, generationBigInt]` |
| `LeanReact.ResourceRequest.mk` | 3 / none | `[encodedToken, cancelledAction, onCleanupClosure]` |
| `LeanReact.Resource.mk` | 5 / `Value, Error` | `[encodedState, refreshAction, readAction]` |
| `LeanReact.ResourceState.idle` | 2 / `Value, Error` | `[]` |
| `LeanReact.ResourceState.loading` | 3 / `Value, Error` | `[encodedToken]` |
| `LeanReact.ResourceState.success` | 4 / `Value, Error` | `[encodedToken, encodedValue]` |
| `LeanReact.ResourceState.failure` | 4 / `Value, Error` | `[encodedToken, encodedFailure]` |
| `LeanReact.ResourceFailure.loader` | 2 / `Error` | `[encodedError]` |
| `LeanReact.ResourceFailure.exception` | 2 / `Error` | `[messageString]` |

Each is `{tag: fullyQualifiedConstructorName, fields: [...]}` as specified in engine/LeanJS/ABI.md. A nested Key uses `LeanReact.Key.mk` with `[string]`. `Except.ok` has `[encodedValue]`; `Except.error` has `[encodedError]`; both omit their constructor type parameters. Use the actual constructor metadata when integrating instead of applying a generic record-field guess.

No intrinsic should be registered for `ResourceTracker.begin/settle/cancel`: those are executable pure reference functions. No native IO implementation under `useResource` should be compiled into the browser. Source signatures relevant to forms, which remain ordinary compiled functions, include:

```lean
LeanReact.useForm {Raw Value : Type}
  (parser : LeanReact.DraftParser Raw Value) (initial : Raw) (site : String := "")
  : LeanReact.Hook (LeanReact.Form Raw Value)
-- Full function arity 5: null, null, parser, initial, site.

LeanReact.FieldBinding.focus {α β : Type}
  (binding : LeanReact.FieldBinding α) (lens : Ontology.Lens α β)
  : LeanReact.FieldBinding β
-- Full function arity 4: null, null, binding, lens.

LeanReact.Form.submit {Raw Value α : Type}
  (form : LeanReact.Form Raw Value) (onValid : Value → LeanReact.Action α)
  : LeanReact.Action (Ontology.Validation α)
-- Full function arity 5: null, null, null, form, onValid.
```

## Scheduling, cleanup, and native-reference limits

A mounted resource starts loading after commit. Its key, enabled flag, and explicit dependency values determine request scope; loader function identity does not trigger another load. Refresh uses the latest committed loader and scope, including through a retained refresh Action. Include every input that should restart loading in the key or dependencies. Dependency counts must remain fixed.

Each start increments a bigint generation per mounted hook instance. Replacement, disabling, and unmount invalidate the old generation, abort its host signal, and drain registered cleanup Actions once in reverse order. Late cleanup registration runs immediately. Old successes, typed failures, and rejected promises cannot publish into the new scope. Cleanup-triggered refresh is handled without overwriting or leaking the newer request. Cleanup failures go to `onCleanupError`, separately from the resource's typed load failures.

Refresh is an `Action Unit` that **starts** the browser request; it is not a promise of its result. Use `state` on subsequent renders or `read` for the controller's current state. `Resource.read` can observe loading before React commits that snapshot; it differs intentionally from P03 `State.read`, which reads committed React state. Disabled or unmounted refresh is a no-op. Changing the key/dependencies clears the visible old result rather than displaying data from another scope.

Native `useResource` queues startup until `Reference.Prepared.commit`, runs a sequential IO loader, supports explicit refresh, and owns cancellation/cleanup. It allocates a fresh controller on each reference invocation. It does not emulate browser scheduling, rerender persistence, or dependency comparisons. `ResourceTracker` separately makes reordered settlement and cancellation executable without pretending native IO ran concurrently. Exception strings are host-specific diagnostics, not a cross-host canonical wire value.

AbortSignal and cleanup offer cooperative cancellation: ignoring them may leave external work running, but its stale result is still suppressed. There is no shared cache, deduplication, automatic retry, Suspense, mutation transaction, or subscription transport. Generated forms and resources still need the parent's concrete adapter/compiler integration tests; the owned tests use actual Lean domain parsing natively and actual React scheduling with deliberately controlled host promises.
