# LeanJS ABI v0 — Lean 4.33.0

## Compiler boundary

`LeanJS` emits JavaScript ESM from **unoptimized pure LCNF**, produced on demand
with `Lean.Compiler.LCNF.toDecl`. This is before specialization, native layout,
unboxing and reference counting. Lean performs match elaboration, proof erasure
and safe recursive-equation lowering. LeanJS walks the resulting executable
transitive dependency graph, emits lexical closures and switches, and supplies
an explicit primitive runtime. It does not interpret source text or substitute
fixture outputs. `tests/compiler/Inspect.lean` shows the inspected representation.

The toolchain is deliberately pinned: these are internal Lean compiler APIs.
LCNF expands `macro_inline` definitions and applies Lean's `csimp` rewrites.
Intrinsic registration targets the **surviving declaration names**. Keep foreign
boundary definitions ordinary `def`/`opaque`, without `macro_inline` or a `csimp`
rewrite bypassing the boundary.

## Values and calls

| Lean value | JavaScript representation |
| --- | --- |
| `Nat`, `Int` | `bigint`, including arbitrarily large values |
| `String` | JavaScript string containing valid Unicode scalar sequences |
| Ordinary constructor | `{ tag: "Fully.Qualified.constructor", fields: [...] }` |
| `Array α` | JavaScript array, treated as immutable |
| Type/proof contents | `null` |
| Function | Callable closure with a numeric `leanArity` property |

Constructor **parameters** are omitted from `fields`; all remaining fields stay
in declaration order, including erased proof/type fields (`null`). Records are
ordinary constructor values, with no one-field unboxing. For example:

```js
// structure Ticket where title : String; priority : Nat; approved : True
{ tag: "Corpus.Ticket.mk", fields: ["hello", 9n, null] }
{ tag: "Option.some", fields: [9n] }
{ tag: "Option.none", fields: [] }
{ tag: "List.cons", fields: [9n, {tag: "List.nil", fields: []}] }
{ tag: "Bool.true", fields: [] }
{ tag: "Decidable.isTrue", fields: [null] }
{ tag: "PUnit.unit", fields: [] }   // `Unit.unit` is a definition reducing to this constructor
```

`Bool` is **not** a JS boolean. `Decidable.isFalse` likewise has one erased proof
field. `Nat.zero/succ` and `Int.ofNat/negSucc` construct and match bigint values.
`Array.mk` converts a tagged list into a JS array. The string-list bridge retains
ordinary `Char.mk` → `UInt32.ofBitVec` → `Fin.mk` constructors, including the two
proof slots; general fixed-width arithmetic is not part of this release.

Types/proofs have no runtime content, but **their function argument slots remain**.
For example, generic `id α x` is `id(null, x)`. Constructor *functions* also receive
parameter slots before discarding them from the constructed object's fields.
Dictionaries and witnesses in `Type` retain computational fields.

Functions use the full pure-LCNF arity, including erased slots. Application may
be partial, exact or over-applied; partial application retains supplied values.
Returned functions and captured local functions remain callable. Zero-parameter
**declarations** are memoized values; zero-parameter local functions are thunks.
Arity counts all leading arrows, including arrows in a returned function type.

Raw JavaScript callbacks use their `Function.length` as arity. For rest/default
arguments, or to explicitly supply an arity, use the generated module's exported
`__leanjs_fn(arity, callback)`. Adapters must pass exactly the intended Lean
arguments: use `xs.map(x => leanFunction(x))`, since native JS `map` supplies extra
index/array arguments that would mean over-application to LeanJS.

Foreign adapters must preserve immutability and supply well-formed values. This
is an in-process execution ABI, not a JSON wire format or untrusted-input decoder.

## Callable compiler and command

```lean
LeanJS.compile (exports : Array Lean.Name)
  (options : LeanJS.Options := {}) : Lean.CoreM String
```

Import `LeanJS` and the application module, then use:

```lean
#lean_js "output.mjs" [MyApp.validate, MyApp.component]
```

Run the file with `lake env lean Export.lean` after the normal library build.
The destination directory must exist. No executable target or root configuration
edit is required. The returned module embeds the primitive runtime and imports
only explicitly registered host modules. There is no Lean runtime dependency in
Node or the browser.

ESM export names are exactly the fully qualified Lean names:

```js
import * as app from './output.mjs';
app['MyApp.validate'](value);
```

`__leanjs` contains the ABI/toolchain version, requested exports, declaration
arities and original types, plus encountered constructor parameter counts, field
counts, field names/types and erasure flags. Constructors seen only in matches or
projections are included too. This is descriptive metadata, not a validator.
`__leanjs` and `__leanjs_fn` are reserved export names. Duplicate exports and
intrinsic registrations are rejected. Declaration symbols and local variable
names are deterministic; output is tested both within one environment and across
separate Lean processes.

## Extensible intrinsic map

```lean
structure LeanJS.Intrinsic where
  leanName : Lean.Name
  module : String
  exportName : String
  arity : Nat

structure LeanJS.Options where
  intrinsics : Array LeanJS.Intrinsic := #[]
  hooks : LeanJS.HookConfig := {}
  opaqueTypes : Array Lean.Name := #[`LeanReact.Hook, `LeanReact.Action, `LeanReact.Element, `LeanReact.Context]
```

Registrations take precedence over native reference bodies and builtins. LeanJS
checks arity against the Lean declaration's type. The imported implementation
receives **all slots**, including erased `null`s, and returns ABI values. An
arity-zero registration imports a value; other registrations import a function.
Module specifiers are relative to the generated ESM file, not the Lean source.
Only names/imports are accepted; application-supplied JS expressions are not.

A complete passing registration is in `tests/compiler/Generate.lean`:

```lean
run_meta do
  let options : LeanJS.Options := { intrinsics := #[{
    leanName := `Corpus.nativeReference
    module := "./intrinsic.mjs"
    exportName := "nativeReference"
    arity := 3
  }] }
  IO.FS.writeFile "tests/compiler/intrinsic-generated.mjs"
    (← LeanJS.compile #[`Corpus.viaIntrinsic] options)
```

LeanJS never imports LeanReact. React should register its primitive boundaries
and return the tagged records/callable closures described here. Host-specific
representations such as Hook/Action must be intercepted consistently at every
operation that constructs or inspects them. Foreign implementations are trusted
contracts; the compiler cannot prove they agree with the native reference.

## Supported and tested surface

- Nat/string literals, lets, applications, partial/over-application, captured and
  higher-order functions, generic functions, record updates and payload variants.
- Typeclass dictionaries, records of functions, generic monadic orchestration
  with `Id` and `Option`, proof erasure without erasing computational witnesses.
- Nested matches (including `Option (Option Nat)`), Fibonacci and a
  well-founded decreasing-Nat recursion compiled from actual Lean definitions.
- Iterative List host builtins for `length`, `foldl`, `map`, `flatMap`, `append`,
  `filter`, `reverse`, `take`, `drop`, `splitAt`, `zip`, `zipWith`, `zipIdx`,
  `replicate`, `range`, `range'`, `foldr`, `getLast?`/`getLast`, `all` and `any`
  (including the `*TR` / auxiliary names Lean's LCNF actually calls). These walk
  cons cells in a JavaScript loop, so a 12,000-element list does not overflow the
  JS stack; the suite also slices 100,000 elements. User-written recursion whose
  self calls are all tail calls compiles to a `while (true)` loop (see below);
  other user-written recursion still uses the JavaScript stack and is reported.
- Exact Nat addition/subtraction/multiplication/division/modulus/power and
  comparisons; subtraction saturates, division by zero returns zero and modulus
  by zero returns its dividend.
- Int arithmetic, sign constructors/matches, Euclidean and truncating division
  and remainder, absolute value, to-Nat, comparisons and decimal rendering.
- String concatenation, scalar length, equality/order, emptiness and list/Char
  conversion, singleton and push. Ordering compares scalars, not UTF-16 units.
  Scalar-indexed slicing through `LeanJS.Portable`: `String.takeScalars`,
  `dropScalars`, `extractScalars`, `scalarLength`, `foldlScalars` and
  `ofScalars` (see below). `Char.toNat`, `Char.ofNat`, Char equality and order.
- Immutable arrays: creation/list conversion, length, push/pop/append, map,
  indexed access, optional/default access and updates, `extract`, `zipWith`/`zip`,
  `foldr`, `findIdx?`, `insertIdx`/`insertIdx!` and `eraseIdx`/`eraseIdx!`.

The exact builtin name/arity table lives in `engine/LeanJS/Compiler.lean`. Ordinary
library functions compose over these primitives; every newly reached native
operation still requires a registered implementation. Array bounds-proof APIs
require valid indices. Panicking `get!`/`set!` raise `RangeError` on invalid
indices; parity claims cover successful calls, not Lean's panic reporting or
fallback behavior. `setIfInBounds` and optional/default reads handle arbitrary
Nat indices through ordinary Lean code.

## Limits and diagnostics

This is an experimental subset backend, not a complete Lean implementation or a
compiler-correctness proof. Arbitrary IO, native FFI, initializers, unregistered
`implemented_by`, unsafe/partial definitions, general fixed-width/Float
operations, byte/string-position operations (`String.Pos`, `String.Slice`,
`Substring`; use the scalar-indexed `LeanJS.Portable` functions), runtime
reflection and unsupported recursors/quotients are not admitted. Raw String
construction and raw matches or projections on String/Array are rejected; use
supported operations instead.
Supported dependent surface (LR-10): proof fields and proof arguments erase to
`null`; subtypes `{ n : Nat // p }` and `Fin n` are the underlying `Nat`;
parameterized structures (`Range n`) are ordinary records plus an erased
parameter; `DecidablePred` is a boolean function; `h ▸ x` / `Eq.mp` on data
lower to identity. Advanced dependent eliminations beyond Lean's successful
pure-LCNF lowering are not claimed. `tests/compiler/ProofFields.lean` is the
fixture. No async scheduler, general trampoline, mutual tail-call
optimization, source maps, incremental compiler cache or bundler is included.
Recursive programs use the JavaScript stack and can exhaust resources, except
the iterative host builtins above and self tail calls, which become loops.

Unsupported native operations fail **before output is written**, with an
executable dependency path and guidance to register an adapter, for example:

```text
LeanJS: unsupported native extern operation
Dependency path: Rejected.root -> Rejected.middle -> Rejected.nativeOnly
Supply a named intrinsic adapter or move this dependency outside portable code.
```

## Scalar-indexed strings and iterative List/Array builtins

Core `String.take`/`String.drop`/`String.extract` and `Substring` work on byte
positions and, in Lean 4.33, return `String.Slice`, a record of byte positions.
That representation is outside this ABI, so those names are **not** lowered.
`engine/LeanJS/Portable.lean` defines scalar-indexed functions whose Lean bodies
are the obvious `String.toList` definitions (the native reference); the compiler
recognises the names and substitutes a code-point loop from `Runtime.js` that
iterates `for (const ch of s)`, never UTF-16 units. A lone surrogate is not a
Unicode scalar and raises `TypeError`. Import `LeanJS.Portable` from portable
code; it has no compiler dependency.

| Recognised name | Slots | Slot layout (erased slots receive `null`) |
| --- | --- | --- |
| `String.takeScalars`, `String.dropScalars` | 2 | `(s, n)` |
| `String.extractScalars` | 3 | `(s, start, len)` |
| `String.scalarLength` | 1 | `(s)`; same value as `String.length` |
| `String.foldlScalars` | 4 | `(β, f, init, s)` |
| `String.ofScalars` | 1 | `(chars : Array Char)` |
| `Char.toNat`, `Char.ofNat` | 1 | `(c)` / `(n)`; invalid scalars map to `'\0'` |
| `instDecidableEqChar`, `Char.instDecidableLt`, `Char.instDecidableLe` | 2 | `(a, b)` → tagged `Decidable` |
| `List.take`, `List.takeTR`, `List.drop`, `List.splitAt` | 3 | `(α, n, xs)`; `splitAt` returns `Prod.mk` |
| `List.takeTR.go` (private), `List.splitAt.go` | 5 | `(α, l, xs, n, acc)` |
| `List.zip` | 4 | `(α, β, xs, ys)` → list of `Prod.mk` |
| `List.zipWith`, `List.zipWithTR` | 6 | `(α, β, γ, f, xs, ys)` |
| `List.zipWithTR.go` (private) | 7 | `(α, β, γ, f, xs, ys, acc : Array)` |
| `List.zipIdx`, `List.zipIdxTR` | 3 | `(α, xs, start)` → list of `Prod.mk [x, index]` |
| `List.replicate`, `List.replicateTR` | 3 | `(α, n, x)` |
| `List.replicateTR.loop` | 4 | `(α, x, n, acc)` |
| `List.range` / `List.range.loop` | 1 / 2 | `(n)` / `(n, acc)` |
| `List.range'`, `List.range'TR` / `List.range'TR.go` | 3 / 4 | `(start, len, step)` / `(step, n, e, acc)` |
| `List.foldr`, `List.foldrTR` | 5 | `(α, β, f, init, xs)` |
| `List.getLast?` / `List.getLast` | 2 / 3 | `(α, xs)` / `(α, xs, proof)`; `RangeError` on `[]` |
| `List.all`, `List.any` | 3 | `(α, xs, p)`; short-circuit, expect tagged `Bool` |
| `Array.extract` | 4 | `(α, xs, start, stop)`; `Array.take`/`drop` lower via their bodies |
| `Array.zipWith` / `Array.zip` | 6 / 4 | `(α, β, γ, f, xs, ys)` / `(α, β, xs, ys)` |
| `Array.foldr` | 7 | `(α, β, f, init, xs, start, stop)`; visits `min(start, size) - 1` down to `stop` |
| `Array.findIdx?` | 3 | `(α, p, xs)` |
| `Array.insertIdx` / `Array.insertIdx!` | 5 / 4 | `(α, xs, i, x, proof)` / `(α, xs, i, x)`; `RangeError` when `i > size` |
| `Array.eraseIdx` / `Array.eraseIdx!` | 4 / 3 | `(α, xs, i, proof)` / `(α, xs, i)`; `RangeError` when `i ≥ size` |

The private `*.go` helpers are the names LCNF produces for `where` clauses of
`@[inline]` core definitions (`_private.Init.Data.List.Impl.0.List.takeTR.go`);
user code never reaches them directly, but the table is complete. Auxiliary
accumulator names keep their core meaning (`takeTR.go l xs n acc` returns `l`
once `xs` is exhausted). `Array.eraseIdxIfInBounds`, `Array.insertIdxIfInBounds`,
`Array.take` and `Array.drop` compile from their reference bodies over these
builtins. The native/Node corpus compares digests of 10,000 random strings
(ASCII, Latin-1, CJK, emoji, ZWJ sequences, variation selectors, U+10000,
U+10FFFF, private use, NUL), lists and arrays, plus `String.dropScalars` on a
100,000-scalar string and `List.take 50_000` on a 100,000-element list.

## Stack safety: self tail calls and recursion diagnostics

Before emitting a declaration, the compiler classifies every call of the
declaration to itself in its pure LCNF body. A self call is a **tail call** when
it is fully applied, its result is returned immediately, and it sits in tail
position: directly in the body, in a match alternative, in a join point, or in a
local function that is itself only ever tail-called from tail position. The last
case covers the shape Lean produces for structural recursion, where each
equation becomes a local `_f.N` bound to `_alt.N` and called from one `cases`
branch, as well as `let rec`/`where` locals, which are separate declarations.

When every self call is a tail call, the declaration is emitted as

```js
$fn(2, (v0, v1) => {
while (true) {
  ... [v0, v1] = [v7, v12]; continue; ...   // self call in the body
  ... return new $Tail([v7, v12]); ...      // self call inside a join point or alternative
  const $r = $app(v14, [v16, v17, v1]);      // tail call of such a local
  if ($r instanceof $Tail) { [v0, v1] = $r.args; continue; }
  return $r;
}})
```

Parameters are rebound simultaneously; locals are re-created per iteration, so
captured values are never stale. `$Tail` requests only travel through tail
positions and never escape as values. Declarations without a self tail call are
emitted exactly as before (the deterministic-output test asserts byte identity
for them), so the lowering is additive and semantics-preserving. Mutual
recursion and calls under a monadic `bind` (for example `Array.forIn'.loop`
with a generic `Monad` dictionary) are not lowered.

Remaining non-tail self-recursion produces an **info** note at compile time:

```text
LeanJS: Corpus.sum (tests.compiler.Corpus:49:0) recurses on the JavaScript stack; 1 self call is not a tail call:
  case List.cons > fun _f.12 > let _x.10 (generated variable v13)
Type: List Nat → Nat
Dependency path: Corpus.observation -> Corpus.sum
Prefer the iterative List/Array/String builtins (engine/LeanJS/ABI.md), ...
```

Each site is described from the outermost match alternative down to the LCNF
binding of the call, with the generated JavaScript variable so it can be found
in the output. `set_option leanjs.recursion.warn true` reports it as a warning
and `set_option leanjs.recursion.error true` rejects the compilation before any
output is written (the options are registered by `LeanJS.Compiler`). The suite
fixes the exact text with `#guard_msgs`, compiles `sumAcc : List Nat → Nat → Nat`,
a `Nat` countdown, a join-point shape and a `where` local to loops, runs them on
1,000,000 elements in Node, and compares them with native Lean on random inputs.

## Checks and integration notes

Run `npm run test:compiler`. The Lean harness builds only owned compiler/test modules
under `tests/compiler/.build`, executes generation, checks deterministic output,
checks rejection diagnostics, runs native Lean to produce canonical JSON, then
runs Node syntax checks and parity tests. It explicitly puts its private build
path first, so a concurrent parent `lake build` cannot select stale compiler
artifacts. No package installation, network, or root edits are needed.

`Runtime.js` is embedded with `include_str`. The root Lake configuration tracks
it using an `input_file` target and the LeanJS library's `needs` field; module
traces include the runtime file. The focused test runner also recompiles
unconditionally. Downstream packages embedding a changed runtime must retain
that dependency. No additional packages are needed.

## P04/P08: array ranges, static Hook validation, and declarations

Top-level initialization and the compiled-library import API are documented in the
[composition guide](../../docs/COMPOSABILITY.md). Generated manifests and TypeScript
types include the library interface, imports, initialization roots, and per-declaration
import ownership. ESM imports preserve the producer's exported value identity.

`Array.foldl` is a seven-slot intrinsic:
`(α, β, callback, initial, array, start, stop)`. `Array.filter` has five slots:
`(α, predicate, array, start, stop)`. Both visit indices in increasing order in
`[start, min(stop, size))`, calling the callback exactly once per visited element.
A start at/beyond the end produces the initial accumulator or an empty filtered
array. Bounds remain bigint until an in-range array index is selected. Filter
returns only accepted elements from that range, in original order, and expects
tagged `Bool.true`/`Bool.false`. Input arrays are never mutated. The native/Node
corpus compares 75 combinations of arrays and bounds, including bounds beyond
2^53. The compiler also lowers the safe reference bodies of `Array.forIn'` and
`Array.foldlM`, retaining generic Monad dictionaries, early exits, and failure
semantics. It does not lower their unsafe native replacements. Other unregistered
native/implemented_by dependencies still require contracts.

`Options.hooks : HookConfig` enables a conservative abstract evaluation of the
pure-LCNF Hook program, before emission. No React module is imported by LeanJS.
The default configuration recognizes the **names** of LeanReact's Hook/Component
API, `Hook.pure/bind/map`, component construction/naming, and state/effect/context
primitives. Each primitive has a checked arity, kind and site-argument index.
For a new trusted primitive, extend the explicit configuration:

```lean
let hooks : LeanJS.HookConfig := {
  primitives := ({} : LeanJS.HookConfig).primitives.push
    ⟨`LeanReact.useResource, 7, "resource", 6⟩
}
-- Use { intrinsics := bridgeImports, hooks } as the compiler options.
```

All exported definitions whose elaborated LCNF result is the configured Hook or
Component type are checked, together with reachable component definitions.
Named custom hooks used inside these boundaries are followed **with their actual
abstract arguments**. Thus a helper such as `useForm parser initial site` can
receive a known literal site from its caller. A separately exported hook taking
an unknown site parameter is rejected. Non-exported helpers are not required to
have a standalone plan independent of their callers.

The evaluator retains closures and dictionary fields needed to resolve sequencing.
It composes the traces of `Hook.bind` and `Hook.map`, and requires all branches
returning a Hook to have the same ordered primitive/kind/site sequence. Initial
values and ordinary render values may depend on props. Pure conditional elements
and conditional/repeated *child element* construction remain valid: children
have separate component boundaries. Actions and Elements are treated according
to their deferred-execution API contracts. Merely constructing a Hook value does
not count as executing it; only the returned/composed Hook program contributes
to its plan.

This is **not global effect inference**. Coverage is limited to the configured
types and combinators and the LCNF programs the evaluator can establish:

- Branches with equal sequences are accepted, even when their initial values
  differ; unequal counts, kinds, labels or ordering are rejected before emission.
- Literal site labels and labels passed unchanged through named helpers work.
  Dynamic labels, including ones computed by an unanalyzed string helper, fail.
- Recursive Hook programs, monadic loops and unknown higher-order Hook calls are
  rejected conservatively. There is no constant-loop unrolling or iteration bound
  proof. Pure arithmetic/data recursion outside Hook execution remains available.
- Conditional Hook dictionaries, opaque/raw Hook constructors without a primitive
  contract, and unsupported abstract results fail. The analysis has a finite fuel
  budget; exhaustion is rejection, never a successful plan.
- Generic exports with an abstract result such as `m α`, or Hooks hidden in
  arbitrary containers, are not independently classified as custom-hook roots.
  Validate their execution through a concrete Hook/component boundary. This does
  not validate arbitrary JS callbacks supplied after compilation, native bodies of
  trusted primitives, or foreign adapters that violate their declared contracts.
- Runtime trace checking remains necessary at the host boundary. Static metadata
  does not automatically configure or replace that runtime check.

A rejection reports the Hook dependency path and the incompatible sequences.
For example, the test suite rejects `ParentWithBadChild -> BadComponent ->
BadBranch` even when the invalid component is only a deferred child. Eight
negative fixtures cover direct/helper/child branch failures, differing sites,
loops, recursion, higher-order calls and dynamic sites. Five positive fixtures
cover named custom hooks, props-dependent values, equal-sequence branches and
conditional children. The real Tickets probe also exercises literal site
propagation through `useForm` and an explicitly registered resource primitive.

The ESM `__leanjs.hookPlans` field contains records of the form:

```json
{"name":"MyApp.Editor","validation":"fixed-hook-sequence-v1","sites":[
  {"primitive":"LeanReact.useState","kind":"state","site":"draft-title"}
]}
```

P08 adds these entry points:

```lean
LeanJS.compileArtifacts (exports : Array Lean.Name)
  (options : LeanJS.Options := {}) : Lean.CoreM LeanJS.Artifacts
-- Artifacts.javascript : String
-- Artifacts.declarations : String
-- Artifacts.manifest : Lean.Json

LeanJS.writeModule (path : System.FilePath) (exports : Array Lean.Name)
  (options : LeanJS.Options := {}) : Lean.CoreM Unit
```

`compile` remains compatible and returns the ESM string. `writeModule` writes
`output.mjs`, `output.d.ts`, `output.d.mts`, and `output.manifest.json` when given
`output.mjs`. The `.d.mts` twin supports Node ESM declaration resolution.
`#lean_js "output.mjs" [Names...]` now uses `writeModule` too. All compilation and
validation finishes before any output is written; the caller must honor errors
because a failed build may leave artifacts from a prior successful build.

Declarations use string-literal ESM export names, exact retained argument slots
(including `null` for type/proof arguments), readonly tagged constructor tuples,
bigint numbers, and readonly arrays. `LeanFunction<Args, Result>` describes full
and prefix partial application, with the remaining `leanArity`. Ordinary callback
parameters accept JS functions, as the runtime does. Concrete structures and
variants receive actual constructor/field types; List/Option use recursive generic
ABI aliases. This is not a React props-object or React-component declaration.

Unknown generic/dependent types and shapes beyond seven expansion levels are
`unknown`. Native-reference fields of host representations are never presented as
browser fields: `Options.opaqueTypes` defaults to Hook, Action, Element and Context
by name. Extend that array when a foreign bridge uses a different representation
for another Lean type. There are no invented browser fields or fabricated nominal
runtime brands. These declarations describe a safe usable subset of the calling
ABI, not every possible dynamic over-application of an unknown generic result.

ESM, declarations and manifests are checked for deterministic generation both
within one Lean environment and across processes. Declaration syntax is checked
with the installed esbuild TypeScript parser, with assertions for retained slots,
tagged fields and opaque results. A TypeScript `tsc` semantic check has **not**
been run: this environment has no installed TypeScript compiler, and no dependency
was downloaded. Consumers need a TypeScript version supporting string-literal ESM
export names and variadic tuple types.

Run the focused suite with `npm run test:compiler`, then the live example
probe with `npm run test:compiler:integration`. The latter re-elaborates local
imports into `tests/compiler/.build` so a concurrent parent build cannot supply
stale interfaces, and evaluates the **unchanged** `examples/lean/Examples/Generate.lean` with its
working directory under `tests/compiler/integration`. Its generated outputs stay
inside that owned directory. It also checks the Tickets hook metadata and parses
its generated declarations. The optional `tests/compiler/Integration.lean`
companion demonstrates `writeModule` on a smaller subset through `reactOptions`.
