# LeanReact implementation plan

This plan executes the [vision](VISION.md) in dependency order. Composable functions, components, and shared domain behavior are the primary acceptance criteria. The first deliverable is a working experimental library with a reproducible example and documented limits. Publishing packages, modifying production deployments, and formal compiler verification are separate release decisions.

## Implementation decisions

- Keep the initial Lean libraries in this repository: `LeanJS`, `LeanOntology`, `LeanContract`, and `LeanReact`. Separate namespaces and imports preserve the eventual package boundaries without coordinating several new repositories before the first working program.
- Pin the installed Lean 4.33.0 toolchain. Start with a specified portable subset and explicit diagnostics for unsupported code.
- Emit JavaScript modules consumed by React. Compile real Lean declarations; hand-authored JavaScript renderers must not stand in for Lean component compilation.
- Keep `Component Props`, `Hook α`, and `Action α` as the component vocabulary. Support callbacks, render functions, custom hooks, and generic component families early.
- Introduce typed field paths and composable codecs before automatic deriving. Ordinary functions and explicit descriptors remain usable throughout.
- Integrate sibling libraries through optional adapters. Keep changes local until the adapter demonstrates which upstream changes are necessary.
- Use an in-memory service interpreter to develop UI independently of storage. Add the native service adapter afterward; do not mistake the test interpreter for a production backend.

## Work packages and dependencies

| ID | Deliverable | Dependencies | Acceptance |
| --- | --- | --- | --- |
| P00 | Build layout, shared ABI, task ownership, and test commands | None | Lean and JavaScript tools have repeatable local entry points. |
| P01 | Portable Lean compiler and primitive runtime | P00 | Compile actual Lean functions with closures, records, variants, and exact integers; execute their generated modules. |
| P02 | Neutral ontology and operation foundations | P00 | Field paths, editors/codecs, service dictionaries, and operation types compose without database or React imports. |
| P03 | React primitives and runtime | P00 ABI | Typed component/element/hooks/actions modules and their JavaScript bridge support state, callbacks, slots, and providers. |
| P04 | Compiler/runtime integration | P01, P03 | A Lean-authored counter and generic list render through React; callbacks retain closure values and state survives keyed reorder. |
| P05 | Shared Tickets domain and component example | P02, P04 | Shared Lean functions drive a board and inbox; one hook supports two layouts; swapping a slot or service needs no copied domain logic. |
| P06 | Forms, queries, and resource operations | P02, P04 | Drafts accept incomplete input, custom editors compose, stale results are ignored, and service errors remain typed. |
| P07 | Optional LeanDB/LeanHttp integration | P02, P05, P06 | Native server and browser client exchange lossless values using explicit public operations; revision conflicts preserve drafts. |
| P08 | Developer tools and independent reuse | P04–P07 | Build/check commands, generated exports, fixtures, and a second consumer work from documented clean commands. |
| P09 | Release qualification | P08 | Appropriate Lean, compiler, runtime, and browser tests pass; supported subset and remaining limitations are explicit. |

P01, P02, and P03 can progress independently after their interface agreement. Integration determines follow-up work. Later vision items such as React Server Components, a WebAssembly backend, distributed live subscriptions, automatic schema migration deployment, and general compiler correctness proofs remain separate expansions driven by real applications.

## P00: establish the project

Create Lake targets for each neutral library and the browser compiler. Create a JavaScript workspace for the runtime and examples. Document the value ABI and intrinsic boundary before independent workers edit either side. Exclude generated modules, dependency directories, build output, and worker receipts from future version control.

Each worker owns named directories. The integrating agent owns root configuration, examples, and cross-library wiring. Workers run focused checks and report exact limitations. They do not commit, publish, or edit sibling repositories.

## P01: compile portable Lean

Prototype lowering from the installed Lean compiler representation or elaborated expressions. Pick the representation on implementation evidence and record the choice. Cover literals, let bindings, functions, applications, records, pattern matching, type-class dictionaries, and a useful subset of recursive functions. Preserve executable closure captures and erase type/proof parameters consistently.

Provide a small runtime for exact natural/integer arithmetic, strings, constructors, arrays, and closure application. Reuse these representations at compiler/runtime boundaries. Reject unsupported native operations with a declaration dependency path. Export deterministic ESM with stable names.

Fixtures compare native and generated results for arithmetic, Unicode text, data constructors, generic higher-order functions, and service dictionaries. A constant string emitted from a Lean tool is not sufficient evidence of a compiler.

## P02: build composable domain foundations

Implement typed paths with composition, optional lenses, entity identity with an explicit scope, and structured validation errors. Implement explicit wire codecs with exact integer handling and combinators for products, options, collections, and tagged alternatives. Begin with manual descriptors; derive them once actual applications expose repetition.

Operation descriptors preserve input, output, and error types. Service dictionaries remain ordinary records of functions parameterized by a monad. Tests show two interpretations of one shared orchestration function and rejection of mismatched field/reference types.

## P03–P04: make Lean components usable

Implement `Component Props`, `element`, DOM constructors, fragments, keyed collections, `Hook`, and `Action`. Add state and callback adaptation, then effects and context. Rendering constructs action values without executing them. Child elements retain component identity and are invoked by React.

Start with function-based element construction; add `view%` syntax as a convenience after that path works. Support render-function props and callbacks without serializing them. Foreign React imports have explicit typed bridges.

Integrate generated Lean with React and test real mounted components. Require local counter updates, a slot override, a custom hook reused in two layouts, controlled/uncontrolled selection, and stable keyed children. Hook placement must either be statically accepted or rejected with a useful diagnostic; conditional hook behavior cannot silently depend on accidental runtime order.

## P05–P06: compose an application

Define Tickets values, summary projections, parsing, and a small service interface in a host-neutral module. Use that module in the browser build and native checks. Compose a generic list or board with ticket cards and a custom footer. Build an inbox by reusing those parts.

Add controlled field bindings, parser-driven drafts, optional/list editors, and a form hook. Supply service access through a provider or explicit dictionary. Add resource state, request identities, stale-response suppression, cleanup, and a revisioned save flow. The same editor behavior supports a dialog and a page.

Track the actual composition exercises: replace a field editor, replace a service, replace layout, add a slot, reuse a projection, and reuse a query fragment. If one needs a framework change, fix the relevant abstraction.

## P07: connect the native backend

Use existing LeanDB and LeanHttp code through adapters with pinned local dependencies for development. Share the neutral domain and public contracts. Keep storage row identity, browser identity, and public projections explicit. Encode large integers losslessly before browser JSON parsing.

Expose a small application-facing registry rather than the whole database argv dispatcher. Check inputs and revisions inside server handlers. Test error-status decoding, conflicts, and a changed client contract. Demonstrate one external HTTP integration with a local fixture server rather than third-party credentials.

Record upstream extraction proposals supported by the working adapter. A composable query description can be developed additively; preserve existing SQL and migration behavior. Updating sibling library internals is justified only by a concrete adapter need.

## P08–P09: developer experience and qualification

Provide commands that build Lean, generate browser modules, run the example, and run focused checks. Document the exact supported language/runtime surface, code-generation restrictions, and foreign binding conventions. Keep generated output deterministic and inspectable. Supply declarations for generated public exports when the representation is stable.

Test from a clean generated-output directory and verify that the second consumer depends on shared modules instead of copying them. Capture compiler/runtime overhead and one realistic rendering workload; record measurements without inventing performance guarantees.

SSR and hydration can be added behind an explicit JavaScript renderer adapter once ordinary component reuse works. Framework-specific RSC integration does not block the experimental release.

## Verification and progress recording

Each package records its changed files, commands, outcomes, and limitations in its worker receipt. The integrator re-runs the relevant checks and updates a progress table here. A step is complete only after its acceptance behavior has run; declarations or placeholder implementations alone do not complete a step.

| Package | State | Evidence |
| --- | --- | --- |
| P00 | Complete | Pinned Lake/npm setup, shared ABI, bounded worker ownership, repeatable build/test commands. |
| P01 | Complete for the portable subset | LCNF-to-ESM compiler; native/Node parity, exact integers, closures, generics, deterministic output, unsupported-dependency diagnostics. |
| P02 | Complete for explicit descriptors | Neutral ontology paths, identities, validation, composable codecs, operation descriptors, and service interpreters; positive and negative Lean tests. |
| P03–P04 | Complete for the function API | Generated components mounted through React; state, callbacks, slots, context, effects, keyed reorder, controlled/uncontrolled inputs, static hook checks, and a foreign React adapter. |
| P05 | Complete | Shared Tickets domain, board/inbox layouts, replaceable footer and editor, one editor hook reused by two layouts. |
| P06 | Complete for local queries and resources | Draft parsers, field/editor composition, neutral query descriptions, request cleanup, stale-result suppression, and revision-aware saves. |
| P07 | Complete for the optional local adapter | Actual LeanDB persistence and LeanHttp round trips, lossless contracts, restart checks, concurrent-save conflicts, and real browser tests. Sibling repositories remain unchanged; upstream proposals are documented. |
| P08 | Complete for experimental tooling | Build/dev/test commands, ESM plus TypeScript declarations and manifests, standalone domain consumer, and rebuild from fresh generated-output directories. |
| P09 | Complete for experimental qualification | Main suite, compiler metadata checks, native SQLite/HTTP checks, and both browser suites passed. Scope, review fixes, measurements, and commands are recorded in [qualification](docs/QUALIFICATION.md). |

The executed scope uses an inline editor and a page to demonstrate behavior/layout reuse; an accessible modal dialog remains a host integration task. `view%` syntax, automatic ontology/codec derivation, automatic TypeScript bindings, incremental code generation, and hydration are deferred. The current API remains usable through ordinary functions and explicit adapters. The query description has a local interpreter, not SQL pushdown. These boundaries are detailed in [implemented scope](docs/IMPLEMENTED.md).

Following the styling and ecosystem discussion, the next composition experiments are Lean-authored style values with CSS extraction and actual shadcn Button/Dialog bindings. Neither is claimed as delivered by P00–P09. Compiler/protocol test orchestration is implemented in `tests/Run.lean`, using the existing Lean toolchain without adding another language or runtime.
