# Frontend readiness review

Reviewed the working tree on 2026-09-06. LeanReact can already support a small CRUD frontend whose components and application behavior are written in Lean, with ordinary CSS and explicit JavaScript host adapters. It is still an experimental foundation for a general frontend toolkit. The next work should concentrate on usable composition, compiler coverage, and browser capabilities.

This review assumes that React, the JavaScript runtime, and reusable host bindings remain part of the implementation. The target is for application authors to write their components, behavior, and shared domain modules in Lean without repeatedly adding application-specific JavaScript plumbing.

## Reproduced issues

### P1: collection form APIs do not compile to JavaScript

An ordinary specialization of `Editor.list` fails during code generation:

```text
FrontendReview.ListEditor
  -> LeanReact.Editor.list
  -> LeanReact.FieldBinding.item
  -> Array.find?
  -> Array.instForIn'InferInstanceMembershipOfMonad
  -> Array.forIn'
```

The compiler reports an `implemented_by` declaration with no intrinsic contract. Calling `DraftParser.list.parse` also reaches the unsupported `Array.forIn'`. The optional-editor specialization compiles successfully.

This prevents using the supplied collection editor and collection draft parser in a browser build, despite their native tests passing. Relevant code is in [Forms.lean](../engine/LeanReact/Forms.lean): `DraftParser.list`, `FieldBinding.item`, and `Editor.list`. Compiler dependency rejection is in [Compiler.lean](../engine/LeanJS/Compiler.lean).

Acceptance for the fix should include a generated, mounted collection form that adds, removes, reorders, edits, and validates rows. Supporting the common iteration operations should also make ordinary application code less likely to hit the same restriction. Native typechecking alone is insufficient for a browser-facing library API.

### P1: independently emitted modules do not share a context declaration

I emitted the existing `Examples.Composition.formatterContext` into module A, then emitted the same context and `Greeting` into module B. Providing A's context around B's greeting produced:

| Composition | Rendered text |
| --- | --- |
| Provider and consumer from B | `Provided: Hello, Lean` |
| Provider from A, consumer from B | `Default: Lean` |

This reproduces in both mounted React and server rendering. Each call to `compileArtifacts` emits its reachable declarations into an independent module. Each resulting context descriptor gets a new React context in [leanjs-react.mjs](../engine/adapters/leanjs-react.mjs). Shared Lean declaration names do not imply shared JavaScript object identity.

One application compiled as a single module can work around this. Independently compiled component libraries need a linking/import model that preserves shared declarations, especially providers and other host resources. Use explicit shared ESM dependencies and package identities. This is a central requirement for the intended cross-project composition.

### P1: a hoisted context can still initialize during render

Compiling only the existing `Examples.Composition.Formatted` component, without explicitly exporting `formatterContext` first, succeeds. Rendering that component throws:

```text
LeanReact context created during render; hoist it to a stable declaration
```

The Lean context is already a top-level definition. Generated declarations are lazy; only exports are forced during module evaluation. Its first use inside the component therefore creates the host context during render. The current example works around this by placing the context before the component in its export list.

The relevant interaction is between lazy declaration/export emission in [Compiler.lean](../engine/LeanJS/Compiler.lean), context creation in [leanjs-react.mjs](../engine/adapters/leanjs-react.mjs), and the render-phase guard in [react.mjs](../engine/runtime/react.mjs). The compiler/runtime should establish host-resource initialization before mounting without requiring application authors to maintain a hidden export-order contract.

## Readiness by area

| Area | Current capability | Work needed for ordinary frontend development |
| --- | --- | --- |
| Component composition | Generic components, callback props, element slots, keyed children, replaceable layouts, and reusable hooks work. | Reliable shared module identity; compile and mount the full public composition surface. |
| Shared domain logic | Typed identities, paths, validation, domain rules, and projections work independently of React. | Browser codecs and transport interpretation still require manually mirrored JavaScript structures. |
| Forms and asynchronous work | Single-field drafts, functional updates, resources, stale-response suppression, and revisioned saves are exercised. | Fix collection compilation; exercise nested forms; add reusable mutation/cache policies as applications need them. |
| Browser interaction | Click/change/keydown snapshots and a small DOM prop surface. | Submit/focus/pointer/file events, synchronous default/propagation control, DOM refs, focus/measurement, and typed browser services. |
| Styling | Ordinary CSS and `className` work. | Lean style values, style-object conversion, CSS extraction, and Tailwind integration are absent. Ordinary CSS remains a valid application path. |
| React ecosystem | A small ordinary React component is bridged; a TypeScript consumer wraps generated Lean components. | Actual library integrations, compound components, ref forwarding, foreign hook contracts, and easier binding authoring. shadcn is untested. |
| Application structure | One demo shell selects local or remote services. | Routing/history/deep links, reusable application configuration, and production build/host integration. |
| Developer experience | Pinned tools, build commands, tests, generated declarations/manifests, public compiler bindings, and watch/rebuild. | General application build configuration, Lean source mapping, faster feedback, and a documented production build. |

`Attribute` currently exposes string/bool attributes and three event constructors. Arbitrary element tags are possible through `node`, but that does not provide arbitrary event handlers, refs, or React style objects. Rich interactions therefore require new typed bindings or a foreign component wrapper.

The example build hardcodes Tickets and Smoke generators, the demo entry point, and its stylesheet. After this review, the repository was separated into `engine/` and `examples/`, and reusable React intrinsic registration moved into `engine/LeanReact/Compiler.lean`; the example supplies its module path. The engine has an independent build target. General application build configuration remains future work. The dev server has no SPA history fallback, and its fixture proxy forwards neither browser authorization/cookie headers nor response cookies. It needs adaptation for an authenticated, routed application.

Some documentation still describes an earlier implementation stage. For example, `engine/LeanReact/API.md` says the compiler hook checker and generated mounting are absent, although both now exist. Conversely, the plan's completed form stage does not establish browser support for the collection combinators reproduced above. Read completion labels as coverage of the exercised experimental slice.

## Recommended sequence

1. **Make the existing composition API work throughout the browser path.** Fix collection iteration coverage and context initialization/identity. Add a cross-module provider test and a generated nested collection form. Preserve ordinary functions and explicit service dictionaries as the main abstraction mechanisms.
2. **Make browser and foreign bindings reusable library values.** Build on the extracted `LeanReact.Compiler` configuration. Add event policies, refs, style objects, and a consistent way to bind modules, components, and hooks. Qualify an actual shadcn Button and controlled Dialog with a custom trigger, keyboard behavior, and focus restoration.
3. **Build one routed application outside the example tree.** Give it list/detail/settings routes, URL state, a collection form, shared providers from another package, remote operations, and failure/retry behavior. Reuse ontology codecs through a general browser transport. The application should expose remaining needs without copying framework internals.
4. **Make that application pleasant to develop and ship.** Add application build configuration, production bundling, source diagnostics, repeatable CI/browser checks, and the styling integration it uses. Expand performance and compatibility testing against this application. Hydration and RSC are separate requirements for applications that need them.

The practical threshold is an independent application that can compose a second Lean library and a real React library without patching the framework for each screen. Small internal tools are already feasible with the current constraints. A comfortable general SPA toolkit is several focused milestones away. Broad production readiness requires further application experience and qualification; the current tests do not justify a percentage-complete or calendar estimate.

## Verification

- `npm test`: passed, including 52 JavaScript tests plus the Lean checks and TypeScript consumer.
- `npm run build`: passed.
- Existing Playwright application and native-service suites: all four browser tests passed in isolated Chrome.
- Additional code-generation probes: optional editor compiled; collection editor and collection parser were rejected as described above.
- Additional context probes: both issues reproduced in server rendering and mounted React.

Local reproductions are retained under ignored `.verification/frontend-review/`. From the repository root:

```sh
lake env lean .verification/frontend-review/Probe.lean
node .verification/frontend-review/context-probe.mjs
node .verification/frontend-review/context-client-probe.mjs
lake env lean .verification/frontend-review/FormsProbe.lean
```

The context probe scripts assert the observed failures. The form probe reports each compilation outcome explicitly. This was a review of the current implementation and its application boundaries, not an exhaustive audit of every compiler lowering or native backend path.
