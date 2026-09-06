# P06 implementation receipt

P06 adds forms and resources to the P03 implementation. It reads and reuses the current Tickets domain and Ontology APIs without editing them. All changes are in the authorized paths; parent adapters/integration, LeanJS, root configuration, and sibling files were untouched. No package installation, network, commits, deletion, external messaging, or additional agents were used.

## Changed files

| File | Change |
| --- | --- |
| `engine/LeanReact.lean` | Imports the two new modules. |
| `engine/LeanReact/Forms.lean` | Parser/draft/field/editor/form APIs with executable Lean implementations. |
| `engine/LeanReact/Resources.lean` | Typed request/state/failure values, pure generation tracker, and native reference hook. |
| `engine/LeanReact/API.md` | P06 API descriptions, complete checked examples, and semantics/limits. |
| `engine/runtime/react.mjs` | Narrow `primitiveHook(kind, site, execute)` host-extension boundary; existing primitives retain their implementations. |
| `engine/runtime/resources.mjs` | React resource scheduler and explicit codec-based semantic intrinsic helper. |
| `engine/runtime/INTRINSICS.md` | Exact new LeanJS function slots, constructor layouts, codec obligations, and lifecycle semantics. |
| `engine/runtime/README.md` | Resource host usage and focused checks; no extra packages required. |
| `engine/runtime/P06-RECEIPT.md` | This receipt. |
| `tests/runtime/check-lean.sh` | Isolated ontology/domain/library compilation and additional P06 checks. |
| `tests/runtime/Forms.lean` | Native composition and validation tests using the actual Tickets title parser. |
| `tests/runtime/Resources.lean` | Native generation, stale-result, refresh, error, and lifecycle tests. |
| `tests/runtime/P06Types.lean` | Generic positive checks and five expected negative type checks. |
| `tests/runtime/P06Examples.lean` | Exact complete P06 example in API.md. |
| `tests/runtime/resources.test.mjs` | Eleven new mounted React resource tests. |

Generated `.olean` files and typecheck logs remain in the ignored, owned `tests/runtime/lean-build/` directory. The script compiles read-only `LeanOntology.Path`, `Validation`, `Identity`, and `Examples.Tickets.Domain` into that same directory and never uses the parent's `.lake` output.

## APIs

`DraftParser Raw Value` separates formatting valid values from parsing arbitrary raw input into `Ontology.Validation Value`. `Draft Raw Value` retains raw input and the separate parsed result. Parser composition includes `ofExcept`, `identity`, `map`, `checked`, `atPath`, accumulating `product`, `optional`, and indexed-error `list`.

`FieldBinding Raw` is an ordinary record with value/set/modify. `ofState`, whole-representation `map`, and lens-based `focus` support typed composition. Focused writes use functional updates and preserve concurrent sibling edits. `present` and key-based `item` bindings become no-ops after removal and do not recreate cleared data.

`Editor Raw` is an alias for `Component (FieldBinding Raw)`. Its `map`, `optional`, and `list` combinators accept ordinary components, callbacks, and layout functions. There is no closed widget enum. List rows use stable keys; applications supply unique IDs.

`useForm parser initial site` exposes draft, binding, action-time read, and reset. `Form.validate`/`submit` use typed parsed results; invalid raw input stays unchanged and never invokes the valid-value callback. The same hook is demonstrated in compact and page layouts. Existing controlled/uncontrolled state composition remains available without another selection abstraction.

`useResource` exposes typed idle/loading/success/failure state, stable key, exact generation, refresh, and controller read. `ResourceFailure` distinguishes typed loader failures from host exceptions. `ResourceRequest` includes its token, cancellation Action, and cleanup registration. The JS host additionally supplies AbortSignal. Replacement, refresh, disable, and unmount invalidate old generations and release owned cleanup registrations, including late registration after cancellation. Old promises cannot overwrite current results. Refresh uses the latest committed loader without treating each fresh closure as a new dependency.

## Exact new signatures and integration

Only one new intrinsic is required. Lean 4.33 directly confirmed:

```lean
LeanReact.useResource {Value Error : Type}
  (key : LeanReact.Key)
  (loader : LeanReact.ResourceRequest → LeanReact.Action (Except Error Value))
  (dependencies : Array LeanReact.Dependency := #[])
  (enabled : Bool := true)
  (site : String := "") : LeanReact.Hook (LeanReact.Resource Value Error)
```

**LeanJS arity 7:** `(null, null, key, loader, dependencies, enabled, site)`, with the erased slots ordered `Value`, then `Error`. The parent must decode the tagged Bool, preserve Key/Dependency semantics, invoke the unary loader closure, decode its Except, and encode ResourceRequest/ResourceState/ResourceFailure/Resource records and their Action fields. Exact constructor tags, field ordering, and full constructor arities are listed in `engine/runtime/INTRINSICS.md`.

The host extension is `createResourceHooks(React, runtime, options)`. `createResourceIntrinsic(runtime, resources, abi)` supplies the five-logical-argument bridge; the parent must provide its concrete codecs and seven-slot wrapper in its own adapter and register it with LeanJS. No concrete parent adapter was edited.

Forms compile normally through existing P03 primitives. Confirmed ordinary source signatures include:

```lean
useForm {Raw Value : Type} (parser : DraftParser Raw Value) (initial : Raw)
  (site : String := "") : Hook (Form Raw Value)
-- Full LeanJS function arity 5: null, null, parser, initial, site.

FieldBinding.focus {α β : Type} (binding : FieldBinding α) (lens : Ontology.Lens α β)
  : FieldBinding β
-- Arity 4: null, null, binding, lens.

Form.submit {Raw Value α : Type} (form : Form Raw Value) (onValid : Value → Action α)
  : Action (Ontology.Validation α)
-- Arity 5: null, null, null, form, onValid.
```

## Exact final tests

`sh tests/runtime/check-lean.sh` — **exit 0**.

- Compiled the minimal ontology/domain dependencies plus every LeanReact module in the isolated test build tree.
- Existing P03 generic checks, five negative type checks, full example, and native reference checks passed.
- P06 form tests passed: actual `Title.parse` errors; empty/overlong raw retention; accumulating field paths and list indices; optional invalid presence; parser map/checked; focused sibling preservation and composed lenses; latest-state mapped updates; invalid submit suppression and valid submit; reset; two layouts; optional clear/late callback; keyed list reorder/removal/append.
- P06 resource reference tests passed: reordered tokens, stale failures, cancellation, wrong key, duplicate settlement, no render/precommit loading, commit/refresh generations, cancellation-aware cleanup, idempotent unmount, late cleanup registration, disabled refresh, typed/exception failures, and cleanup-triggered refresh ownership.
- Five new negative checks rejected wrong raw parser input, editor field type, lens type, submit callback type, and loader request type. Total expected type rejections: **10**.
- Both complete API examples compiled.

`node --test tests/runtime/*.test.mjs` — **exit 0; 31 passed, 0 failed, 0 skipped**.

The 20 existing tests passed unchanged. Eleven new tests mount actual React and cover deferred start; deliberately reordered refresh promises; key/dependency replacement; stale failures; retained refresh handles; latest loader closure; unmount and late cleanup; typed errors, rejected promises, synchronous errors and recovery; disabled resources; Strict Mode; cleanup-error reporting; malformed loader results; dependency-shape diagnostics; explicit request/result/state codecs; and reentrant refresh from cleanup without leaks.

A Python equality check passed for both complete Lean code blocks in `engine/LeanReact/API.md` against `tests/runtime/Examples.lean` and `tests/runtime/P06Examples.lean`. Direct Lean `#check` output confirmed the new intrinsic signature and constructor layouts. No added axioms or `sorry` occur in the new library modules.

## Limits and parent follow-up

The native Hook model still allocates fresh state/controllers per invocation. Resource loading is sequential IO on explicit commit/refresh; no native browser scheduler or dependency-diffing is claimed. The pure tracker tests settlement ordering honestly without pretending concurrent IO ran. Browser refresh starts work and returns Unit; it does not await the value. Resource read observes current controller state, while ordinary form reads use P03 committed React State.read semantics.

Form validation is synchronous. There is no dirty/touched policy, automatic reset/merge, async field validator, generated editor registry, or verified parser/lens law requirement. Immediate set-then-submit in one React action does not flush queued state; validate explicit new input or submit after commit. Optional/list keys and replacement policies remain caller-owned.

Resource cancellation is cooperative: ignoring AbortSignal/cleanup can leave physical work running, but stale delivery is suppressed. There is no shared cache, deduplication, automatic retry, Suspense, mutation transaction, or transport layer. The P03 static hook-checker limitation remains; resources participate in the existing dynamic trace/plan interface.

The parent still needs to wire the one new intrinsic and test generated Lean forms/resources through the concrete adapter/compiler. No hand-authored JS Tickets/domain/form rule substitutes for that integration. The owned tests provide native domain evidence and independent mounted React scheduling evidence. No product/ops decision blocks the handoff.
