# P04/P08 compiler integration receipt

Historical worker receipt. The test scripts named below have since been replaced
by `tests/Run.lean`. Current commands are `npm run test:compiler` followed by
`npm run test:compiler:integration`; both use Lean. See
[qualification](../../docs/QUALIFICATION.md) for subsequent integration results.

Implemented within LeanJS and tests/compiler only. Parent Examples, adapters,
React/runtime and ontology source files were read and compiled but not edited.
All probe output and isolated .olean files stay under tests/compiler.

## Changes

- `engine/LeanJS/Compiler.lean`: checked seven-slot `Array.foldl` and five-slot
  `Array.filter` contracts, Hook validation during dependency traversal,
  hook-plan metadata, configurable opaque declaration types, `Artifacts`,
  `compileArtifacts`, and `writeModule`. `compile` remains compatible.
- `engine/LeanJS/Runtime.js`: range-aware immutable fold/filter implementations. Bigint
  start/stop bounds are compared before converting a valid array index to Number.
- `engine/LeanJS/Hooks.lean` (new): a bounded pure-LCNF abstract evaluator for the
  configured Hook/Component API. It retains closure/dictionary information,
  follows named custom hooks contextually, composes sequences, and rejects
  inconsistent or unknown Hook execution paths. LeanJS still imports no React.
- `engine/LeanJS/Declarations.lean` (new): ABI declarations with erased null slots,
  bigint, tagged readonly tuples, readonly arrays, generic List/Option aliases,
  prefix partial application and conservative unknown types.
- `engine/LeanJS/ABI.md`: exact new contracts, coverage, commands and limitations.
- Tests updated: `Corpus.lean`, `Native.lean`, `Generate.lean`, `Negative.lean`,
  `Deterministic.lean`, `compiler.test.mjs`, `run.py`, `README.md`, `.gitignore`.
- Tests added: `Hooks.lean`, `integration.py`, `integration.test.mjs`,
  `Integration.lean` (optional companion), `HookInspect.lean` (inspection probe).
- This receipt: `engine/LeanJS/INTEGRATION_RECEIPT.md`.

## Verification

Final checks:

```sh
python3 tests/compiler/run.py
python3 tests/compiler/integration.py
lake env sh -c 'export LEAN_PATH="$PWD/tests/compiler/.build:$LEAN_PATH"; lean tests/compiler/Hooks.lean'
```

All exited 0. The focused runner uses `lake env env LEAN_PATH=... lean` with the
owned build directory first; it builds each compiler module and the corpus,
generates ESM/declarations/manifests twice, verifies reproducibility within one
environment and across processes, checks rejections, obtains canonical results
from native Lean, and executes Node syntax checks and its test runner.

- **7 compiler/Node tests passed**, including native/Node parity and declaration
  syntax/shape checks. New array parity covers 75 array/start/stop combinations
  for both fold and filter, including empty/reversed/out-of-range slices and
  bounds above 2^53. Callback order and input immutability also pass.
- **7 native-dependency rejection checks passed.** Direct `Array.foldlM` still
  fails with its implemented_by dependency; diagnostics were not bypassed globally.
- **5 Hook-positive fixtures passed:** named custom hook reuse, fixed sequencing,
  props-dependent initial/result values, equal-sequence branches and conditional
  child elements.
- **8 Hook-negative fixtures passed:** direct/helper/child branch inconsistency,
  differing sites, loops, recursion, unknown higher-order calls and dynamic sites.
  Failures occur before emission and include Hook dependency paths.
- **2 live Tickets integration tests passed:** expanded static component plans and
  declaration syntax/ABI shapes.

`integration.py` recursively re-elaborates local imports into the owned build
path, avoiding concurrent parent source/.olean races. It then compiles the actual
**unchanged** `examples/lean/Examples/Generate.lean`, through the current `Examples.reactOptions`
and bridge, with its working directory under `tests/compiler/integration`.
The parent generator now calls `writeModule`; it emitted:

```text
tests/compiler/integration/generated/tickets.mjs
tests/compiler/integration/generated/tickets.d.ts
tests/compiler/integration/generated/tickets.d.mts
tests/compiler/integration/generated/tickets.manifest.json
```

The checked live plans include App's `local-store`, Workspace's resource/effect/
state sequence (including `tickets-query` and `tickets-snapshot`), Counter's
`count`, and identical Editor/PageEditor sequences of `draft-title`, `save-notice`.
The parent resource primitive contract is used explicitly; no resource effect
semantics were silently inferred from its native implementation.

Declaration syntax is checked with installed esbuild; shape assertions verify
actual null slots, tagged fields and opaque host results. There is **no tsc
semantic-check claim**: TypeScript is not installed and nothing was downloaded.

## Parent invocation

```lean
LeanJS.writeModule "examples/generated/tickets.mjs" exportNames Examples.reactOptions
```

This writes ESM, `.d.ts`, `.d.mts`, and `.manifest.json` after successful validation.
`#lean_js "output.mjs" [Qualified.names]` does the same with default options.
Use `compileArtifacts` for an in-memory `{ javascript, declarations, manifest }`
result; `compile` still returns only JavaScript. No new root target/dependency is
needed. The existing `Runtime.js` include_str rebuild note still applies.

New Hook primitives require a named intrinsic import **and** an explicit
`HookPrimitive` contract. For example the current parent config extends
`HookConfig.primitives` with `⟨LeanReact.useResource, 7, "resource", 6⟩` (as a Lean
Name). Hook plans are in `manifest.hookPlans`; adapters may consume each plan's
`kind`/`site` fields. Static metadata does not automatically configure the host.

## Limits

This is conservative validation of concrete configured Hook/component boundaries,
not global effect inference. Custom hooks are analyzed with actual abstract call
arguments. Unknown higher-order Hook programs, recursive/looping Hook sequences,
dynamic labels, raw Hook construction and fuel exhaustion are rejected. Equal
branch sequences are accepted. Elements/Actions follow the trusted deferred API
contract; foreign code and generic abstract-monad exports are not globally
verified. Runtime trace checks remain necessary for host callbacks and adapters.

Declarations safely use unknown for generic/dependent/depth-limited or configured
opaque representations; they do not claim native Hook/Action implementation
fields or plain React props. They describe known full/prefix application, not every
dynamic over-application of an unknown generic result. General native operations
remain behind the existing dependency diagnostics. Pure array fold/filter support
does not extend to arbitrary monadic fold/filter or native effects.
