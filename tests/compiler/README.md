Run from the repository root:

```sh
npm run test:compiler
```

This requires the pinned installed Lean 4.33.0, Lake and Node (tested on Node 24). No
network or package installation is used. `tests/Run.lean` builds the compiler and
corpus in `.build/` using the Lake environment, compiles imported declarations to
`generated.mjs`, and compares canonical results produced by native Lean and Node.
The generated modules and `native.json` are disposable test artifacts, never
hand-authored outputs.

`Corpus.lean` exercises exact arithmetic beyond 2^53, negative/zero divisors,
Unicode scalars and string ordering, records and proof slots, payload/nested
variants, closure capture, polymorphism, typeclass dictionaries, interchangeable
services, generic monadic code under Id/Option, list recursion, Fibonacci,
well-founded recursion and immutable arrays. `Native.lean` and
`compiler.test.mjs` independently encode the results for comparison. Both also
run the same deterministic generator over 10,000 random strings (emoji, ZWJ
sequences, astral scalars), lists and arrays through the scalar string and
iterative List/Array builtins, comparing digests and leading samples; Node
alone checks 100,000-element slicing for stack safety.

`Generate.lean` demonstrates both public entry points. `intrinsic.mjs` is a tiny
trusted foreign primitive; its deliberately distinguishable result tests that
registration overrides the native reference and receives a live callback.
`Negative.lean` checks dependency paths and rejects native IO/externs,
implemented_by, unsafe/partial definitions and mismatched intrinsic arities, and
fixes the exact non-tail recursion note with `#guard_msgs`, including its
`leanjs.recursion.warn`/`error` escalation. `Deterministic.lean` checks repeated
compilation in one environment and that self tail calls (`sumAcc`, `countLoop`,
`sumEven`, `sumWhere.go`) emit `while (true)` loops while other declarations are
untouched; the runner also compares output across two processes. `Inspect.lean` is an optional LCNF
inspection tool.

The compiler and adapter contract is [LeanJS/ABI.md](../../engine/LeanJS/ABI.md).

P04/P08 additions:

- `Hooks.lean` checks fixed custom-hook sequencing and conditional children, and
  rejects inconsistent branches (including deferred invalid children), loops,
  recursion, unknown higher-order hooks and dynamic labels before JS emission.
- Array range parity covers 75 array/start/stop combinations for `foldl` and
  `filter`, with bigint bounds beyond 2^53. Direct `foldlM` remains a negative test.
- The generator now emits `.d.ts`, `.d.mts`, and `.manifest.json` alongside ESM.
  The suite parses declarations with installed esbuild and checks their actual
  erased-slot/tagged-field ABI. The root `npm test` additionally runs the installed
  TypeScript compiler against the independent consumer; this focused runner does
  not download tools.
- `npm run test:compiler:integration` re-elaborates current local example
  imports into the owned `.build`, then compiles the unchanged
  `examples/lean/Examples/Generate.lean` with its current bridge into `integration/examples/generated/`.
  It runs two additional checks of Tickets hook plans and declaration syntax.
  Run the focused suite first to build the current compiler. Both commands invoke
  `lake env lean --run tests/Run.lean` with the corresponding mode; the integration
  mode uses Lean's import parser to find source dependencies.

`HookInspect.lean` is an optional LCNF inspection probe for the actual Tickets
components. `Integration.lean` is an optional smaller `writeModule` example;
The `integration` runner mode runs the actual parent generator instead.
