# Experimental interface agreement

This is the historical coordination agreement for the first compiler/runtime implementation, not a current contributor assignment or a stable public API. For the implemented representation contract, read the [LeanJS ABI](../engine/LeanJS/ABI.md). For application assembly, read [LeanApp interfaces](FULLSTACK_INTERFACES.md). Current contribution guidance lives in the [frontend guide](HOW_TO.md#check-and-debug-your-work).

The original agreement follows.

## Ownership

- Compiler worker: `engine/LeanJS.lean`, `engine/LeanJS/`, `tests/compiler/`.
- Ontology worker: `engine/LeanOntology.lean`, `engine/LeanOntology/`, `engine/LeanContract.lean`, `engine/LeanContract/`, `tests/ontology/`.
- React worker: `engine/LeanReact.lean`, `engine/LeanReact/`, `engine/runtime/`, `tests/runtime/`.
- Integrating agent: root Lake/npm configuration, `examples/lean/Examples/`, `examples/`, `scripts/`, integration tests, documentation, adapters.

No worker edits another worker's files or root configuration. Publish interface notes in the owned directory if an early implementation needs a change.

## Values and calls

Prefer a simple, inspectable representation in the first backend:

- Lean strings map to JavaScript strings, with Lean-compatible Unicode operations.
- `Nat` and `Int` use bigint; wire codecs serialize exact values deliberately.
- Data constructors use a documented uniform tagged representation. The compiler worker chooses and documents the exact tag/field convention in `engine/LeanJS/ABI.md` before runtime integration.
- Type/proof erasure and function arity follow a single documented convention chosen by the compiler worker. Generic functions and closure values must be supported.
- The compiler exposes an intrinsic map from fully qualified Lean declarations to named JavaScript implementations. React operations use this map rather than arbitrary JavaScript strings embedded in application code.

## Compiler public entry point

Expose a callable Lean code-generation function and a command or CLI accepting imported modules and exported declaration names, producing an ESM file. It must compile actual Lean definitions and reject unsupported transitive dependencies. The worker documents its exact entry point and a passing command in `engine/LeanJS/ABI.md`.

React intrinsic registration must be extensible without making the compiler library import React. The parent will connect the compiler to the React runtime using this registration boundary. Include enough declaration/type metadata to implement the adapter if the backend uses specialized object representations.

## React source vocabulary

The primary surface is `Component Props`, `Hook α`, `Action α`, `component`, `element`, `text`, `fragment`, `keyedEach`, `useState`, and typed DOM/event helpers. Keep components composable through values, functions, and callbacks. Avoid requiring explicit message or effect types for simple components.

Give primitives native reference definitions when useful, and list required compiler intrinsics in `engine/runtime/INTRINSICS.md`. Do not attempt to infer the compiler's calling convention; use an explicit wrapper module during integration. Ordinary JavaScript runtime tests can exercise the bridge independently in the first pass.

## Dependencies

All Lean libraries initially belong to a single Lake package and depend only on Lean/Std unless the integrating agent adds an adapter dependency. The JavaScript runtime uses React as a peer dependency and uses Node's test runner or the root-provided test environment. Workers must not install dependencies or change package manifests; report needed dependencies to the integrator.

React 19.2.8, react-dom 19.2.8, jsdom 29.1.1, and esbuild 0.28.2 are installed at the repository root. Runtime tests can use them now. Root test orchestration will discover `tests/runtime/*.test.mjs`; document a different test command if needed.
