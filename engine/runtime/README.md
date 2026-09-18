# LeanReact runtime

[LeanApp documentation](../../docs/README.md) · [LeanReact guide](../../docs/LEANREACT.md)

This is an ESM library bridge within LeanApp. It does not start a server, render a static website, or depend on a generated compiler module. The host supplies React; the compiler adapter integrates the separate [intrinsic contract](INTRINSICS.md).

Required host packages: matching `react` and `react-dom` versions (tested with 19.2.8). Tests additionally use `jsdom` (tested with 29.1.1) and Node's built-in test runner (tested with Node 24.11.1). The runtime itself needs no bundler or TypeScript transpiler; this repository's root workspace supplies its development dependencies. The .mjs bridge is usable from JavaScript or TypeScript; standalone TypeScript declaration files are not supplied yet.

```js
import * as React from "react";
import { createRoot } from "react-dom/client";
import { createRuntime, hook } from "./runtime/react.mjs";

const runtime = createRuntime(React);
const Counter = runtime.component(() => hook(() => {
  const state = runtime.runHook(runtime.useState(0n, "count"));
  return runtime.dom("button", {
    type: "button",
    onClick: runtime.onPress(state.modify(n => n + 1n)),
  }, [runtime.text(`Count: ${state.value}`)]);
}), { name: "Counter", hookPlan: [{ kind: "state", site: "count" }] });

// The host provides a DOM container.
export function mount(container) {
  const root = createRoot(container);
  root.render(runtime.element(Counter, undefined));
  return () => root.unmount();
}
```

The example demonstrates the independent host API; it is not a substitute for compiler integration. Hook values are lazy synchronous computations; Action values are lazy event/effect computations which may return promises. `pureHook`, `bindHook`/`mapHook` (on the runtime), `pureAction`, `bindAction`, `mapAction`, and `catchAction` compose these values. Use an injected runtime's `runHook` only inside its component render or another Hook. `runAction` is the explicit host runner and is forbidden during render.

`component` returns a stable React function. Create definitions outside rendering and reuse them. `element` carries arbitrary props, including closures and render props, inside one `leanProps` property; it never JSON-serializes or spreads application props. `foreignElement` is the explicit bridge for conventional React components; `handleElement(Component, props, { onReady, onGone, adapt })` adds an imperative handle whose operations resolve to `{ok:false}` after unmount instead of touching a stale ref. `keyedEach` uses keyed Fragments so multi-node rows preserve identity as a group and duplicate sibling keys produce errors.

`createRuntime(React, { onActionError, onCallFailure })` also takes a global `onCallFailure(failure)` hook, called once for every `CallFailure`-shaped error (`name === "CallFailure"`, string `kind`) surfacing from an action, effect, or published resource failure; returning `true` marks an action error handled. `runtime.configure({ ... })` replaces either handler later.

`onPress` and `onSubmit` accept an already constructed Action; `onSubmit` always calls `preventDefault()` first. `onClick`, `onChange`, `onKeyDown`, `onKeyUp`, `onFocus`, `onBlur`, `onInput`, `onPaste`, `onMouseEnter`, `onMouseLeave`, and `onScroll` accept payload-to-Action functions and snapshot primitive data synchronously (paste reads `clipboardData` during dispatch). An `onKeyDown` action resolving synchronously to the string `"preventDefault"` stops the browser default; an asynchronous `"preventDefault"` is reported to `onActionError` because it is too late. Callback construction may happen in render; callback actions run at the event boundary. Managed effects use `useEffect(dependencies, setupAction, site)`; setup must return a cleanup Action. Supply `onActionError` to `createRuntime` to report rejected asynchronous actions/effects. The default rethrows errors.

Run focused checks from the repository root:

```sh
sh tests/runtime/check-lean.sh
node --test tests/runtime/*.test.mjs
```

The Lean script compiles library modules into the owned `tests/runtime/lean-build/` directory, checks positive and negative types and the complete API examples, then executes native reference tests. JS tests mount actual React roots in jsdom; missing dependencies cause a visible failure, not a silently skipped suite. The action-only tests need no React or DOM: `node --test tests/runtime/actions.test.mjs`.

See [LeanReact/API.md](../LeanReact/API.md) for the Lean authoring surface and native-reference limits. `npm test` adds generated-component/resource integration and compiler static hook checks. `npm run test:browser` exercises real-browser rendering separately. These focused runtime tests do not establish browser compatibility, general hydration support or application performance.


`router.mjs` adds the `router` hook primitive: `createRouterHooks(React, runtime, { history })` returns `useLocation(site)` (`{location, navigate, replace, back}` over `pathname + search`), with `createBrowserHistory(window)` and `createMemoryHistory(initial)` as interchangeable histories, plus the URL helpers behind the Lean `Route.*`/`Query.*` intrinsics. `runtime.onNavigate(action)` is the link-click adapter. See [the router contract](INTRINSICS.md#router).

P06 adds `resources.mjs`: initialize `createResourceHooks(React, runtime)` once and execute its `useResource(key, loader, dependencies, enabled, site)` Hook inside a component. A loader returns an Action whose result is `{ok:true,value}` or `{ok:false,error}`; thrown/rejected host errors become separate exception failures. Requests provide a token, AbortSignal, cancellation Action, and cleanup registration. Refresh, dependency changes, disabling, and unmount invalidate prior generations. See [the P06 contract](INTRINSICS.md#p06-forms-and-resource-integration) for source signatures, exact erased slots, record layouts, and codec obligations.

`node --test tests/runtime/resources.test.mjs` mounts resources in actual React with controlled promises. The full test command includes these tests and the existing P03 suite. The Lean check script additionally compiles the minimal ontology/domain dependencies into its own build directory, tests forms against the actual Tickets parser, runs the resource reference model, and checks the P06 examples and five additional expected type errors. No extra packages are needed for P06.
