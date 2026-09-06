# Collections, initialization, and compiled libraries

The collection form APIs now compile to JavaScript. Top-level values initialize before rendering, and compiled libraries can import shared declarations without recreating them. The runnable examples stay under `examples/`; the implementation stays under `engine/`.

## Collection forms

[`Examples.Collections`](../examples/lean/Examples/Collections.lean) composes `Editor.list`, stateful row components, a caller-supplied layout, focused field bindings, `DraftParser.product`, `DraftParser.list`, and `Form.submit`. Open `/?example=collections` after `npm run dev`.

Rows have stable IDs. Reordering preserves their local state and input nodes. Field updates find the current row by key and preserve sibling fields. Validation retains invalid raw input, accumulates errors across fields and rows, and reports paths using the current array index. Removing an invalid row removes its errors; submitting an empty collection is valid for this example's parser.

The compiler lowers the safe Lean reference bodies of `Array.forIn'` and `Array.foldlM`. This also enables `Array.find?` and ordinary array `for` loops. The caller's monad, `break`, `continue`, short-circuit failure, callback order, and erased membership-proof slots are retained. The native unsafe implementations are still rejected. These reference loops use the existing recursive JavaScript backend; this change does not add stack-safe general recursion.

## Top-level value lifetime

Reachable zero-argument declarations are initialized after all generated declaration thunks exist and before public exports are exposed. Dependencies can therefore refer forward to one another, while each value is evaluated once per module instance. Functions remain callable values; initialization does not execute their bodies.

A top-level context works when only a component that uses it is exported. The same applies when a context is held in a top-level record produced by a factory. Application authors no longer need to export contexts first or maintain an initialization list. `__leanjs.initialized` records the generated initialization roots.

Creating a fresh context inside a render function remains a lifetime error. Hoist the context or the result of its factory into a top-level declaration. This is separate from Lean's native `initialize` commands, which remain outside the portable compiler subset. The current React adapter still requires erased bindings for native `TypeName` instances.

## Linking libraries

A library identifies itself with `LibraryId`: package name, version, and module name. Its public interface lists the actual Lean export names, retained arities, and declaration type-expression hashes. The manifest also records the pinned Lean version and value ABI. These checks catch stale or mismatched declarations; they are not a semantic compatibility proof or a substitute for versioning changes to record layouts, host bindings, or behavior.

Compile the shared declaration once and import that library from each consumer:

```lean
-- Producer build; options contains the application's normal React bindings.
LeanJS.writeModule "out/shared.mjs" #[`MyProject.formatterContext]
  { options with library := some ⟨"my-project", "1.0.0", "Shared"⟩ }

-- Consumer build. The .olean/source imports make the Lean declaration available;
-- this manifest selects its JavaScript implementation and preserves its identity.
let shared ← LeanJS.readLibrary "out/shared.manifest.json" "./shared.mjs"
LeanJS.writeModule "out/components.mjs" #[`MyProject.Greeting]
  { options with libraries := #[shared] }
```

The import specifier is resolved relative to the consumer's generated ESM. An npm package specifier also works. The consumer emits a direct named import for a shared value or function; it neither recompiles the body nor wraps the imported value in a new function. `Artifacts.asImport` provides the same interface directly when both builds run in one Lean process. `Options.library` is optional for standalone output.

The compiler rejects ambiguous ownership, overlapping intrinsic registrations, self-imports, and mismatched declaration signatures or toolchain/ABI versions. Generated modules check the producer's interface again during ESM evaluation. The manifest's `imports` and declaration `importedFrom` fields make the selected dependencies inspectable.

[`GenerateComposability.lean`](../examples/lean/Examples/GenerateComposability.lean) builds a shared context library, a provider library, a consumer library, and an application that imports the latter two. Both branches of this dependency graph import the same shared ESM file. Open `/?example=libraries` to see context updates reach the separately compiled consumer while its state is preserved.

Use one owner for each shared declaration, export it from that owner's public interface, and configure that dependency in consumers. Dependencies must resolve to the same ESM instance for shared identity. Independently emitted standalone bundles remain independent; display names are never globally interned. Separate contexts with the same display name remain separate. Cyclic library dependencies, automatic package discovery, and resolving duplicate installed copies are not implemented by this linker. Configure overlapping reexports through their owning library rather than assigning one declaration to two imports.

## Verification

- `npm test` covers native/generated array parity, library configuration diagnostics, generated collection validation, automatic initialization through a factory and record, and shared contexts in server rendering and mounted React. It also checks nested providers, independent contexts with the same display name, preserved component state, and rejection of a mismatched runtime library interface.
- `npm run test:browser` exercises add/edit/reorder/remove/validate, error paths, empty collections, retained row DOM/state, and live updates between the separate provider and consumer libraries. It includes the existing Tickets browser checks.
- The original direct-context example now exports its components without exporting its context. Its existing mounted test remains a regression check for that review finding.
