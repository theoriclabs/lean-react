# P03 implementation receipt

P03's source library and independent React bridge are implemented. Compiler integration remains the parent's P04 task. All edits are within the four authorized paths. No root configuration, sibling, ontology, compiler, or application-example files were edited; no packages were installed; no agents, network, commits, or publishing were used.

## Changed source files

| File | Purpose |
| --- | --- |
| `engine/LeanReact.lean` | Public library imports. |
| `engine/LeanReact/Core.lean` | Component/Element, Hook/Action monads, state, events, keys, context, effects, native trace validation. |
| `engine/LeanReact/DOM.lean` | Typed common, button, input, label, and anchor props and DOM constructors. |
| `engine/LeanReact/Reference.lean` | Executable preparation/render/action/commit/cleanup reference interpreter. |
| `engine/LeanReact/API.md` | Full API guide with complete, checked example code and explicit limitations. |
| `engine/runtime/actions.mjs` | Lazy sync/async managed actions, composition/error handling, and phase guard. |
| `engine/runtime/react.mjs` | Injected React runtime, components, keys, hooks, callbacks, providers, effects, trace diagnostics. |
| `engine/runtime/intrinsics.mjs` | Explicit semantic intrinsic table requiring caller-supplied backend codecs and closure identity. |
| `engine/runtime/INTRINSICS.md` | Required Lean declarations, logical bridge signatures, ABI obligations, validation plan, and P04 acceptance work. |
| `engine/runtime/README.md` | Host usage, required packages, commands, and test scope. |
| `engine/runtime/P03-RECEIPT.md` | This receipt. |
| `tests/runtime/.gitignore` | Ignores owned native build artifacts. |
| `tests/runtime/check-lean.sh` | Focused library compilation, positive/negative type checks, example check, native execution. |
| `tests/runtime/Probe.lean` | Generic composition signatures and five expected type rejections. |
| `tests/runtime/Examples.lean` | Exact code included in API.md. |
| `tests/runtime/Reference.lean` | Executable state/action/hook/effect/context/callback/slot/key checks. |
| `tests/runtime/actions.test.mjs` | Three compiler/React-independent action and host-adapter tests. |
| `tests/runtime/react.test.mjs` | Seventeen actual React/jsdom behavior tests, including the abstract ABI adapter protocol. |

`tests/runtime/lean-build/` contains generated `.olean` files and the expected-negative-typecheck log. These are ignored build products, all inside the owned tests directory.

## Implemented APIs

- `Component Props`, `component`, `Component.named`, `element`; arbitrary callback, component, and render-function props remain ordinary values.
- `Element`, `text`, `empty`, `node`, `fragment`, `keyed`, `keyedEach`, and string/Nat/scoped Key helpers. Child rendering is deferred; duplicate sibling keys are diagnosed.
- `Hook α` and `Action α` with monadic sequencing and map; reusable custom hooks; no event enums or explicit effect rows.
- `useState` with render snapshot `value`, deferred `set`, functional `modify`, and action-time `read`.
- Typed DOM props and immutable PressEvent/ChangeEvent/KeyEvent snapshots.
- `Context α`, `createContext`, `useContext`, `provide`, and `provider` with nearest-provider lookup and defaults.
- `useEffect` with explicit dependencies and setup returning deferred cleanup. JS supports async setup/cleanup, including cleanup returned after unmount. Native setup failure releases already acquired resources.
- Runtime action/render guards, committed hook-trace validation, named custom-hook scopes, and an optional hook-plan interface. No static checker is claimed.
- Explicit foreign React element and host Action building blocks on the JavaScript side.

## Exact final verification

Environment: Lean 4.33.0; Node v24.11.1; React 19.2.8; react-dom 19.2.8; jsdom 29.1.1. React/DOM dependencies were already provided by the parent when checked.

`sh tests/runtime/check-lean.sh` — **exit 0**.

- Compiled `Core`, `DOM`, `Reference`, and the `LeanReact` entry point.
- Checked generic API signatures and all complete API examples.
- Five negative checks rejected wrong component props, Action used as Hook, wrong DOM event payload, wrong event action result, and wrong state-set value.
- Executed native reference checks for deferred construction, repeated functional updates, immutable render snapshots, hook-trace mismatch, effect setup/cleanup/idempotence, rollback after failed setup, nested context scope/default restoration, callback capture, render slots, child hook boundaries, keyed content, namespace collision avoidance, and duplicate-key diagnostics.
- Final output: `LeanReact typechecks passed (generic APIs and 5 expected rejections).` and `LeanReact reference checks passed (state/actions, hooks, effects, context, callbacks, slots, keys).`

`node --test tests/runtime/*.test.mjs` — **exit 0; 20 passed, 0 failed, 0 skipped**.

Coverage: lazy sync/async action sequencing and recovery; phase rejection; deferred and explicitly encoded host results; actual button updates and new callback props; keyed reorder preserving both state and DOM identity; custom hooks reused in two layouts; controlled/uncontrolled picker composition; nested function-bearing service context; dependency-sensitive effects and cleanup; Strict Mode resource balance; cleanup after late async setup; event snapshotting and actual checkbox updates; function-valued state; foreign React callbacks/slots; observed hook removal and first-render hook plans; duplicate keys and component construction during render; async error reporting; explicit ABI-codec/closure adapter mounting; same-kind labeled hook swaps and impure updaters; retained state handles reading the latest committed state.

A Python equality check also passed: the `lean` code block in `engine/LeanReact/API.md` exactly matches `tests/runtime/Examples.lean`, which the Lean command compiled. No broader/compiler tests were run or claimed.

## Required parent work and limitations

Implement the `abi` codec/call/closure/record interface against the compiler worker's actual `engine/LeanJS/ABI.md`; register the fully qualified intrinsic table and preserve the monad dictionaries' primitive boundaries. Opaque host handles must not be accessed through native-reference record projections. Remove type/proof parameters and the native context TypeName dictionary explicitly according to compiler metadata. Preserve component identities without collapsing distinct factory captures. Mount genuinely generated Lean components and run the P04 counter/list/callback/context/effect checks. The current adapter test intentionally uses a separate test-only encoding.

Native execution is a single-render reference model: fresh state cells per invocation, explicit effect commits, no reconciliation/rerender scheduler or dependency diffing. React implements persistent mounted state and lifecycle behavior. `State.read` reads committed state in React and does not flush queued updates.

Static hook placement, source syntax/annotations, query/resource hooks, request cancellation/stale-reply protection, generated foreign source bindings, real-browser qualification, SSR/hydration, and performance measurements are not implemented. Context creation needs a native TypeName instance and a unique stable name. `Action.ofIO` and native `Action.catchError` are not portable browser capabilities. The runtime supplies dynamic diagnostics and a concrete plan/trace interface; it cannot prove all branches safe or distinguish unlabeled same-kind swaps.

Required packages are documented in engine/runtime/README.md; no additional product/ops decision blocks the parent from integrating this work.
