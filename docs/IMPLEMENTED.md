# LeanReact implementation and limits

[Documentation](README.md) · [LeanReact](LEANREACT.md)

This page covers the frontend library, compiler/runtime integrations and local Tickets fixture. Authentication and the hosted café are separate LeanApp integrations; their qualification is recorded in [release evidence](RELEASE.md).

The implementation compiles real Lean declarations to JavaScript and runs them through React. The public source API uses `Component Props`, `Hook α`, and `Action α`. This document describes the current boundary.

## Composition exercised by the examples

| Change | Reused pieces | Evidence |
| --- | --- | --- |
| Switch a board to an inbox | `ListView`, `TicketList`, `Card`, the same ticket values | Browser tests |
| Replace a card footer | A `TicketSummary → Element` prop | Browser tests |
| Use editor behavior in a page and an inline panel | `useTicketEditor`, `useForm`, `editorBody` | Browser tests |
| Replace an input with a textarea while keeping the draft | `FieldBinding String`, an editor component prop | Browser tests |
| Replace local storage with a remote service | The same compiled `Workspace`, an ordinary `TicketService Action` record | Native browser tests |
| Reorder stateful children | `keyedEach`, stable component definitions, scoped keys | Generated-component integration tests |
| Supply a function-bearing provider | `Context Formatter`, a nested component | Generated-component integration tests |
| Share a context across compiled libraries | One shared ESM dependency, independently compiled provider and consumer | Mounted/SSR integration and browser tests |
| Compose a collection form with nested field validation | `Editor.list`, `DraftParser.list/product`, focused fields, stateful keyed rows | Generated validation and browser tests |
| Call a foreign React component | A named intrinsic with a typed Lean reference, callback, and child element | Generated-component integration tests |
| Build a form from typed controls | `DOM.form`, `textarea`, `select`, blur validation, paste snapshots, `KeyOutcome` | Generated-component integration, reference and browser tests |
| Drive an imperative JavaScript widget | `foreign`, `Handle`, `HandleResult`, a `useCell`-held handle, `registerForeign` | Generated-component integration, reference and browser tests |
| Route between screens | A `Route` type with a `RouteCodec`, `routerProvider`, `useRoute`, `Router.link` | Generated-component integration, reference and browser tests |
| Extend a saved query | `openTickets`, `inboxTitles`, `Query.filter/map/take/cross` | Lean and generated-domain tests |
| Consume domain behavior outside React | `examples/generated/domain.mjs` | Independent Node consumer and TypeScript checks |

These changes use existing functions and values. Domain modules import neither SQLite nor React. The browser and native service use the same `Title.parse` and `applySave` definitions.

## Source and host boundaries

`engine/` contains the reusable Lean libraries, JavaScript runtime, and React bridge. Its default Lake build excludes examples. `LeanReact.Compiler` supplies reusable intrinsic registration and hook configuration; applications provide the JavaScript module path for their output location.

`examples/lean/Examples/Tickets/Domain.lean` contains the example's values and behavior. `Contracts.lean` defines its public codecs and operations. `Components.lean` contains its components, hooks, and local service interpreter. `Queries.lean` extends neutral query descriptions. The web entry point, independent consumer, application adapters, and native server also live under `examples/`. The `examples/lean` source root preserves `Examples.*` imports without a filesystem case collision. Generated modules and browser assets live in `examples/generated/` and `examples/dist/`.

`LeanJS` lowers Lean's pure LCNF representation to ESM. Its intrinsic registry replaces native reference implementations at named boundaries. The compiler keeps exact integers as `bigint`, ordinary constructor values as tagged records, and closures as callable JavaScript functions. Generated `.d.ts`, `.d.mts`, and manifest files describe that ABI. They do not pretend encoded Lean records are plain JavaScript objects.

`engine/adapters/leanjs-react.mjs` is the concrete value adapter. Lean component descriptors retain their render closure and name; a stable React wrapper owns each descriptor's identity. State, events, resources, and providers cross this adapter. `examples/consumer/typescript.tsx` shows how an ordinary TypeScript component wrapper uses generated Lean constructor types.

The native reference interpreter supports explicit rendering, events, and effect commits. It is useful for Lean tests and does not implement React reconciliation. The browser uses React's actual state and lifecycle.

`WorkspaceProps.serviceKey` is a mount boundary. Changing it creates an independent workspace, so pending actions from one service cannot update another service's editor or rows. Refreshes within the same service preserve drafts; incoming list values cannot replace a newer saved revision.

## Styling and the JavaScript/TypeScript ecosystem

The current styling path is ordinary CSS. The demo loads `examples/web/style.css`, which the build copies into `examples/dist/`. Lean components select classes through typed DOM props:

```lean
DOM.div { className := some "card" } #[text "A styled Lean component"]
```

Inline styles use `style : Array (StyleProp × String)`, a closed enum of React's camelCase property names mapped to a React `style` object; values remain strings. There is no typed CSS value API, CSS module integration, or Tailwind build step yet. Composable Lean rules, tokens, and variants with static CSS extraction are the intended next styling layer. They should remain optional and compose with stylesheets and utility classes.

Interop works in both directions, through explicit adapters. `examples/lean/Examples/Foreign.lean` gives a foreign React component typed props, an action callback, and an element slot; `examples/adapters/example-foreign.mjs` maps them into an ordinary React component. Imperative components use `foreign name { props, onReady, onGone }`: the host adapter registered with `registerForeign` exposes its API through `useImperativeHandle`, and Lean receives a `Handle` whose operations resolve to a typed `.unmounted` result after the component is gone. `examples/lean/Examples/Sparkline.lean` and `examples/adapters/example-sparkline.mjs` drive a canvas this way. The mounted integration suite exercises both. Conversely, `examples/consumer/typescript.tsx` wraps a generated Lean component with `asReactComponent` and checks the generated declaration types. The standalone domain module can also be imported from Node without React.

This is a manual binding foundation. Tagged Lean records, `bigint` integers, erased argument slots, action values, and callbacks need deliberate host conversion. There is no automatic TypeScript binding importer or general npm compatibility guarantee. Foreign components keep their own React hooks inside their React boundary. Wrapping a complete JavaScript component is often the smallest useful adapter.

shadcn is not installed or tested in this repository. Its normal React components are candidates for these adapters, with the Tailwind and theme setup required by its [manual installation guide](https://ui.shadcn.com/docs/installation/manual). A Button or Card wrapper is a useful first integration. Dialog, Select, and polymorphic trigger composition need explicit contracts and browser checks for controlled values, callbacks, refs, portals, focus, and child forwarding. Imperative access goes through the typed `Handle` protocol above; the Lean DOM API does not provide refs on ordinary DOM elements or an `asChild` forwarding abstraction.

## Tooling languages

The compiler is Lean (`engine/LeanJS/`), the native server is Lean, and the browser runtime and build scripts use JavaScript/TypeScript. `tests/Run.lean` handles compiler fixture builds, deterministic output comparisons, isolated example compilation, the native JSON protocol/restart checks, and HTTP readiness. It uses Lean's process, filesystem, JSON, and import-parsing APIs. These tests run with the existing pinned Lean toolchain and Node; there is no Python dependency or additional test runtime.

## Hooks and asynchronous work

Code generation checks exported hooks and reachable component definitions for a fixed primitive hook sequence. It follows named custom hooks with their actual arguments. Conditional child elements and callback actions remain ordinary composition. Hook branches with different sequences, dynamic site labels, and unsupported higher-order or repeated hook execution receive diagnostics. The runtime also compares committed hook traces.

Custom hooks can forward a literal site label supplied by their caller. A component must ultimately have a statically known sequence. For a stateful collection, render a keyed child component for each item. Hoist component-family specializations such as `TicketList := ListView TicketSummary` so their React type stays stable.

`useResource` uses request keys, generations, and committed dependencies to suppress obsolete results. It retains cleanup actions, aborts its host request signal when ownership ends, and keeps domain loader failures distinct from recognised transport failures (`ResourceFailure.call` with the portable `Contract.CallFailure`) and from unexpected host exceptions. An adapter must actually pass that signal to its I/O to stop work; `resourceLoader` in `engine/LeanContract/Service.mjs` does so over `createHttpClient`, and the Tickets browser adapter uses it for the list query, so unmount and rapid refreshes abort the in-flight `fetch`. `createRuntime({ onCallFailure })` is the global hook for reacting to a failure kind once.

`State.read` reads the latest committed React value. It does not flush queued updates. Use functional `modify` operations when updates depend on previous state. Actions are deferred and cannot execute during rendering. The browser `Action.catchError` bridge converts host exceptions to `IO.Error.userError`; typed service failures remain values in `Except`.

The local service uses `useCell`, whose `Cell.modifyGet` performs an immediate synchronous transition and returns its result. This lets two saves in one React batch observe each other's revisions. Cells do not request rendering; queries and ordinary React state drive the view. They are local capabilities, not a replacement for the native server's mutex and database transaction.

## Ontologies, forms, and queries

The neutral libraries provide typed paths, optional lenses, scoped nominal IDs, structured validation, descriptors, codecs, and typed operation interpreters. Explicit codec values allow more than one representation of a type. Exact wire integers use canonical decimal strings; optional values retain nested absence distinctions. Record codecs reject unknown fields, and independent field errors accumulate.

Forms keep raw input separate from parsed values. Field bindings support representation mapping, lens focus, optional children, and keyed collection edits. Editors and layouts are caller-supplied components/functions. Derivation and a default widget registry are not required.

The collection example exercises adding, editing, reversing, and removing rows, preserving local row state and DOM identity, and accumulating validation paths across nested fields. The compiler supports `Array.forIn'` and `Array.foldlM` through their safe Lean reference bodies, including ordinary `for` loops and `Array.find?`.

Top-level values initialize automatically before rendering. `LeanJS.Options.libraries` imports public declarations from compiled libraries using their manifests; contexts and components keep their object identity across those imports. See [collections and library linking](COMPOSABILITY.md) for the build API, runnable examples, and dependency constraints.

`Ontology.Query` is a typed description of local stages with a reference interpreter. It supports reusable filters, projections, limits, concatenation, and products. It preserves their written order. Its function fields are local executable values; this is not a serializable SQL language, and there is no SQL pushdown optimizer. The native adapter uses existing LeanDB persistence APIs. [Native adapter notes](NATIVE.md) propose upstream changes based on that integration.

## Wire and native integration

The SQLite adapter separates public IDs from row IDs and stores revisions as text. Writes use a mutex, a transaction, and the shared revision rule. A stale save returns the current persisted ticket. The browser preserves the draft, can load the current revision, and can retry explicitly.

The server exposes only the two declared operations and a manifest. It validates operation identity, version, kind, and input. Both browser and LeanHttp adapters decode non-success response bodies, including conflicts. Version negotiation is explicit equality, not automatic structural compatibility or semantic-digest inference.

Browser wire codecs, TypeScript types and the embedded manifest are generated from the public manifest by `LeanContract.Generate` ([generated client](FULLSTACK_INTERFACES.md#generated-client)); the Tickets and café examples use the generated modules, and a small hand-written bridge converts wire values to LeanJS constructors with the compiled domain parsers. The generated codecs check schema shape only; validation beyond a schema stays on the server. The alternative of running the Lean `Codec` values in the browser by making a `Lean.Json` subset portable in LeanJS was rejected for now: a larger compiler change and larger bundles for the same wire checks. Lean's JSON parser also collapses duplicate textual object keys before codec validation.

## Current limits

- The compiler is pinned to Lean 4.33.0 and supports a documented subset. Arbitrary IO/FFI, unsafe or partial definitions, unregistered native primitives, general Float/fixed-width operations, and advanced dependent eliminations are outside that subset. `Repr`/`reprStr` are not portable (`Std.Format.pretty` is partial and reaches `String.Internal.*`); `toString` on `Nat` is.
- Recursion whose self calls are all tail calls (accumulator style, `let rec`/`where` locals, structural recursion over `List` or `Nat` that returns the recursive call) compiles to a `while (true)` loop and runs on a million elements. Other self-recursion uses the JavaScript stack and receives a compile-time info note naming the function and its call sites; `set_option leanjs.recursion.warn true` makes it a warning and `set_option leanjs.recursion.error true` an error for CI. Prefer, in order: the iterative host builtins below, an accumulator-passing form, then chunking the input. Mutual recursion and recursion under a generic monadic `bind` (including `for` loops over arrays with a generic `Monad`) are not lowered.
- Core `String.take`/`drop`/`extract` and `Substring` are byte-position (`String.Slice`) operations and are not portable. `LeanJS.Portable` supplies scalar-indexed `String.takeScalars`, `dropScalars`, `extractScalars`, `scalarLength`, `foldlScalars` and `ofScalars`; their Lean bodies are the native reference and the compiler substitutes code-point loops.

## Iterative host builtins

These names compile to JavaScript loops rather than to their Lean bodies; the exact slot layouts are in the [compiler ABI](../engine/LeanJS/ABI.md).

| Family | Host builtins | Lower through their reference bodies |
| --- | --- | --- |
| `String` | `append`, `length`, `isEmpty`, equality/order, `toList`, `ofList`, `singleton`, `push`, `takeScalars`, `dropScalars`, `extractScalars`, `scalarLength`, `foldlScalars`, `ofScalars` | `intercalate` |
| `Char` | `toNat`, `ofNat`, equality, `<`, `≤` | — |
| `List` | `length`, `foldl`, `map`, `flatMap`, `append`, `filter`, `reverse`, `take`, `drop`, `splitAt`, `zip`, `zipWith`, `zipIdx`, `replicate`, `range`, `range'`, `foldr`, `getLast?`, `getLast`, `all`, `any` (with the `*TR`/auxiliary names LCNF calls) | pattern matching, `Option.getD`, other List functions (JS stack) |
| `Array` | `mk`, `toList`, `size`, `push`, `pop`, `append`, `get`/`get!`/`getD`, `set`/`set!`, `foldl`, `filter`, `map`, `extract`, `zipWith`, `zip`, `foldr`, `findIdx?`, `insertIdx`, `insertIdx!`, `eraseIdx`, `eraseIdx!` | `take`, `drop`, `insertIdxIfInBounds`, `eraseIdxIfInBounds`, `forIn'`, `foldlM`, `find?`, `xs[i]?` |

The compiler suite compares the native and generated results of every builtin on 10,000 random inputs, including strings with emoji, ZWJ sequences and astral-plane scalars, and slices 100,000-element strings and lists without stack growth.

- The function-based DOM API is implemented, including form controls, focus/blur/input/paste/key/mouse/scroll payloads, `tabIndex`, `data-*`, common `aria*` attributes and a typed inline `style`. Elements or events outside that surface still go through `node` and `Attribute.string`/`.bool`. JSX-like `view%` syntax, automatic ontology derivation, incremental code generation, and source-level JavaScript maps are not implemented. The bundler emits ordinary JavaScript source maps.
- Native `TypeName` instances used only by context reference semantics need explicit erased intrinsic bindings. Context export ordering is automatic; contexts created inside render still need to be hoisted.
- Routing is the minimal typed router in `LeanReact.Router`: an application route type with a codec, `useRouter`/`routerProvider`/`useRoute`, `Router.link`, `pushState`/`replaceState`/`back` over `pathname + search`, same-origin only, with an in-memory reference history. Nested routes, loaders, and code splitting are not provided. Route codecs use the intrinsic-backed `Route.*`/`Query.*` helpers until portable string splitting lands in LeanJS.
- There is no shared query cache, distributed subscription protocol, optimistic mutation framework, hydration qualification, or React Server Components integration. React server rendering is exercised as a workload check.
- The native server is a local fixture adapter. Authentication, authorization, deployment, and package publication are separate work. It binds loopback by default.

The [compiler ABI](../engine/LeanJS/ABI.md), [ontology API](../engine/LeanOntology/API.md), [React API](../engine/LeanReact/API.md), and [native guide](NATIVE.md) contain the detailed contracts and focused commands.
