# P01 implementation receipt

Historical worker receipt. The test scripts named below have since been replaced
by `tests/Run.lean`. Use `npm run test:compiler` for the current Lean harness;
see [qualification](../../docs/QUALIFICATION.md) for the subsequent rerun.

Implemented the portable compiler from actual Lean 4.33.0 declarations through
pure LCNF. The native/Node corpus demonstrates composition through closures,
generic functions, dictionary records, typeclasses, Id/Option monads, immutable
records/arrays, payload variants, Unicode strings, exact Nat/Int arithmetic,
structural recursion and well-founded recursion.

## Files

- `engine/LeanJS.lean`: public import.
- `engine/LeanJS/Compiler.lean`: LCNF lowering, dependency validation, deterministic ESM,
  primitive contracts, intrinsic registration, metadata and `#lean_js`.
- `engine/LeanJS/Runtime.js`: embedded primitive runtime and callable closure ABI.
- `engine/LeanJS/ABI.md`: early interface agreement, finalized with coverage and limits.
- `engine/LeanJS/RECEIPT.md`: this receipt.
- `tests/compiler/Corpus.lean`: actual Lean fixture declarations.
- `tests/compiler/Generate.lean`: command and callable compiler examples.
- `tests/compiler/Native.lean`: native canonical result generation.
- `tests/compiler/Negative.lean`: rejection/path/arity checks.
- `tests/compiler/Deterministic.lean`: same-environment reproducibility.
- `tests/compiler/Inspect.lean`: optional LCNF inspection tool.
- `tests/compiler/compiler.test.mjs`: Node/native comparison and ABI checks.
- `tests/compiler/intrinsic.mjs`: deliberately distinguishable foreign test primitive.
- `tests/compiler/run.py`, `README.md`, `.gitignore`: repeatable focused checks.

Generated artifacts remain only in `tests/compiler/`: `.build/`, `generated.mjs`,
`intrinsic-generated.mjs`, and `native.json`. No root configuration, example,
ontology, React, runtime-adapter or sibling-repository files were modified.

## Exact final checks and results

- `lake env lean engine/LeanJS/Compiler.lean`: exit 0, no diagnostics.
- `node --version`: `v24.11.1`.
- `python3 tests/compiler/run.py`: exit 0, all checks passed.

The runner obtains the Lake environment and places the owned test build directory
first in `LEAN_PATH`. It executes Lean file checks/builds for `Compiler.lean`,
`engine/LeanJS.lean`, and `Corpus.lean`; runs `Generate.lean` twice and
`Deterministic.lean`; runs `Negative.lean`; and runs native
`lean --run tests/compiler/Native.lean`. It then executes:

```sh
node --check tests/compiler/generated.mjs
node --test tests/compiler/compiler.test.mjs
```

Node result: **5 tests passed, 0 failed**. The parity test includes 36 natural
arithmetic input pairs, 49 signed input pairs including zero/negative divisors,
49 Unicode string-order pairs, and the composition/container/recursion cases.
The other tests cover live foreign callbacks, partial/over-application,
immutability and erased proof fields, intrinsic overrides, and constructor/type
metadata. Output was byte-identical across repeated calls and separate processes.
Final generated corpus ESM: **88,585 bytes**, including runtime and metadata.
This is a corpus size, not a bundle-size or performance claim.

All six negative checks passed: transitive native extern, implemented_by,
unsafe declaration, partial recursion, native IO dependency, and intrinsic arity
mismatch. Example actual diagnostic:

```text
LeanJS: unsupported native extern operation
Dependency path: Rejected.root -> Rejected.middle -> Rejected.nativeOnly
Supply a named intrinsic adapter or move this dependency outside portable code.
```

## Entry points and handoff

- Callable: `LeanJS.compile : Array Lean.Name → LeanJS.Options → Lean.CoreM String`
  (options default to `{}`).
- Command: `#lean_js "output.mjs" [Namespace.declaration, ...]` in any Lean file
  importing `LeanJS` and its application declarations; use `lake env lean` after
  the ordinary library build. No executable target is needed.
- React adapter: supply named imports through `Options.intrinsics`, including
  erased argument slots. LeanJS has no LeanReact import.
- Parent build note: track `engine/LeanJS/Runtime.js` as an additional compiler input,
  or force recompilation of `LeanJS.Compiler` on runtime edits, because Lean's
  `include_str` does not add a Lake dependency. The focused runner already forces
  compilation. No package dependencies are requested.

Not supported: arbitrary IO/FFI/initializers, unregistered implemented_by,
unsafe/partial definitions, general Float/fixed-width operations, byte/string
positions, runtime reflection and unsupported dependent recursors/quotients.
Raw native String/Array representation operations are rejected. Recursion uses
the JS stack; no trampoline, TCO, source maps or compiler-correctness proof is
claimed. Panic APIs throw JS errors, and native parity claims cover successful
calls rather than native panic fallback/reporting. See `ABI.md` for the exact
representation and primitive boundary.
