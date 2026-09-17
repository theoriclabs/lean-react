---
name: leanreact
description: Build, extend, and debug LeanReact frontends using Lean components, shared ontologies, forms, and compiled library imports. Use for application work or compiler/runtime integration in a LeanReact checkout; ordinary React-only work does not need this skill.
---

# LeanReact development

Build the behavior the user requested using ordinary Lean functions, typed props, callbacks, child elements, and service records. Prefer composability and expressiveness over adding proof obligations or a framework-specific configuration language. The [how-to guide](docs/HOW_TO.md) contains a complete buildable form and task-specific recipes.

## Locate the implementation

Resolve the links in this skill relative to the LeanReact checkout. Confirm the current working tree and read the relevant source before changing it; the vision and historical receipts are not the current API contract.

| Location | Purpose |
| --- | --- |
| `engine/LeanReact/` | Components, hooks, actions, DOM, forms, resources, and native reference behavior |
| `engine/LeanOntology/`, `engine/LeanContract/` | Shared domain and transport abstractions |
| `engine/LeanJS/` | Portable Lean-to-ESM compiler and ABI |
| `engine/runtime/`, `engine/adapters/` | JavaScript host runtime and LeanJS/React bridge |
| `examples/lean/Examples/` | Application modules and generation programs |
| `examples/web/`, `examples/adapters/`, `examples/native/` | Showcase, example host bindings, and optional native server |
| `scripts/build.mjs`, `scripts/test.mjs`, `tests/Run.lean` | Actual build and verification entry points |

Keep reusable engine code and application code in their separate directories. Shared application ontologies can live in their own application/library module; they need not move into the engine. The project's tooling languages are Lean and JavaScript/TypeScript. Do not introduce Python or another toolchain for application code or test orchestration.

## Choose a maintained example

Read only the example and reference relevant to the task:

- Components, callback props, generic lists, interchangeable fields/layouts, service injection: [Tickets components](examples/lean/Examples/Tickets/Components.lean).
- Raw drafts, focused fields, keyed collection rows and accumulated errors: [Collections](examples/lean/Examples/Collections.lean), [Forms API source](engine/LeanReact/Forms.lean).
- Shared contexts and separate compiled libraries: [library generator](examples/lean/Examples/GenerateComposability.lean), [linking guide](docs/COMPOSABILITY.md).
- Shared domain rules, IDs, and operations: [Tickets domain](examples/lean/Examples/Tickets/Domain.lean), [contracts](examples/lean/Examples/Tickets/Contracts.lean), [ontology source](engine/LeanOntology.lean).
- A foreign React component or a TS consumer: [Lean binding](examples/lean/Examples/Foreign.lean), [host adapter](examples/adapters/example-foreign.mjs), [TS consumer](examples/consumer/typescript.tsx).
- Runtime/ABI or unsupported compiler dependencies: [compiler](engine/LeanJS/Compiler.lean), [ABI](engine/LeanJS/ABI.md), [implemented scope](docs/IMPLEMENTED.md).
- Optional LeanDB/LeanHttp integration: [native guide](docs/NATIVE.md). This path depends on sibling checkouts.

## Implement through the existing boundaries

`Component Props` is a definition; `element definition props` creates a child element. Hoist definitions and generic specializations so React identity survives rerenders. Give stateful rows stable unique keys that are independent of position and editable content.

A `Hook α` runs during render. An `Action α` is deferred work. Keep a fixed hook sequence with literal site labels; conditionally render children rather than conditionally executing hooks. Event callbacks return actions. Do not run actions while constructing elements or disable the hook checker to get a build through.

Use functional state updates for changes based on prior state. `State.read` reads the latest committed value and does not flush queued React updates. `Cell.modifyGet` is an immediate local transition returning `(result, nextValue)`; cells do not rerender. Use it when immediate local coordination is actually needed, as in the memory service or ID allocator.

Keep invalid input in a raw draft. Compose `DraftParser` values and `FieldBinding.focus` lenses. A focused setter preserves sibling fields using the latest owner value. `Editor.list` takes row/layout functions and a key function; a retained keyed binding follows reorder and becomes a no-op after removal. Exercise these behaviors through generated code.

Keep domain failures as typed values. `useResource` owns request generations and stale-result suppression; an I/O adapter must forward its abort signal to cancel underlying work. `Action.catchError` handles host exceptions separately from typed service failures.

## Generate and link the real application

Use `LeanReact.Compiler.options runtimeModule` for the standard bindings. Adapter module paths are resolved from generated ESM, not from the Lean generator file. Extend `options.intrinsics` only for a concrete host boundary, with the actual retained arity, including erased type/proof slots.

Build an application module before running a generator that imports it. In this workspace:

```sh
lake build Examples.YourModule
lake env lean -R examples/lean examples/lean/Examples/YourGenerator.lean
```

These names are task-specific: use the actual module and generator. `npm run build` only runs the generators and entries registered in `scripts/build.mjs`. Wire in new entry points or provide an explicit application build command. Editing generated ESM is not a source fix.

Top-level values, including contexts inside records, initialize automatically. Do not add context exports merely to arrange initialization. A context factory called inside render still needs to be hoisted. Native `TypeName` instances currently need explicit erased intrinsic bindings; use their actual Lean declaration names.

For shared identity, emit the owning library with `Options.library`, then load its manifest with `LeanJS.readLibrary` and pass that import in consumers' `Options.libraries`. `Artifacts.asImport` is available within one build process. Both provider and consumer must resolve to one shared ESM instance. Standalone bundles are independent, and equal display names are not shared identity. Resolve interface mismatches against the producer and consumer sources; do not bypass checks or invent global name interning.

Generated `Nat`/`Int` values are `bigint`; records/variants are tagged values and type/proof slots are `null`. Inspect `.d.mts` and manifest output. Prefer exported constructors or explicit codecs to guessed record layouts. Use `__leanjs_fn` for foreign callbacks whose JS parameter count does not reflect their intended arity.

Ordinary CSS plus `className` is supported. Foreign React components need deliberate bindings. Do not assume a CSS DSL, JSX-like Lean syntax, general DOM refs/events, Tailwind, shadcn, a router, or automatic TS binding generation exists. Add a missing capability when the user's concrete task warrants it; describe and test the host contract.

## Verify the boundary that changed

Choose checks that exercise the requested behavior; do not treat successful elaboration as successful browser compilation.

| Work | Validation |
| --- | --- |
| Application composition | Build its Lean module, run its actual generator, then mount/interact with that generated output. |
| Forms or keyed rows | Invalid/valid submission; add/edit/reorder/remove; retained state and current error paths. |
| Shared libraries | Separately generated provider/consumer with a shared import; defaults, updates, and identity. |
| Compiler/ABI | `npm run test:compiler`; use native/generated parity for a new lowering contract. |
| Tickets generator integration | `npm run test:compiler:integration` after the compiler suite. |
| Host runtime | `npm run test:runtime` and relevant generated integration tests. |
| Existing application browser flows | `npm run test:browser`; Chromium or a configured Chrome executable is needed. |
| Full regular checks | `npm test`. Native server checks remain optional unless that path changed. |
| Website appearance | Inspect desktop/mobile rendering; `npm run screenshots` regenerates README captures. |

For unsupported native declarations, inspect the full dependency path. `Array.forIn'` and `Array.foldlM` safe reference bodies are supported, but arbitrary IO/FFI is not portable. Keep the compiler's rejection behavior intact when adding a narrowly defined capability.

`List.length`, `foldl`, `map`, `flatMap`, `append`, `filter` and `reverse` (including the `*TR` names Lean's LCNF actually calls) are iterative host builtins; a 12,000-element list is in the compiler suite. User-written recursive List functions, `List.range`, and `Repr`/`reprStr` still use the JavaScript stack or hit native Format/`String.Internal` externs. `toString` on `Nat` is portable (`Nat.repr`). For errors and enums, write an explicit `code`/`label : α → String` as `Cafe.Model` does.

Report what changed, which generated/runtime behavior was verified, and material remaining limitations. Preserve the user's requested scope and existing authorization.
