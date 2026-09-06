# LeanReact engine

This directory contains the reusable implementation. Engine Lean modules and JavaScript modules do not import example application code.

| Directory | Responsibility |
| --- | --- |
| `LeanOntology/` | Shared paths, identities, validation, descriptors, codecs, and query descriptions |
| `LeanContract/` | Typed operations and transport interfaces |
| `LeanReact/` | Components, hooks, actions, forms, resources, and native reference behavior |
| `LeanJS/` | Lean-to-JavaScript compiler and generated value ABI |
| `runtime/` | Reusable JavaScript React/action/resource runtime |
| `adapters/` | Concrete LeanJS-to-React representation bridge |

From the repository root, `npm run build:engine` or `lake build` builds the engine, including the optional `LeanReact.Compiler` integration module. It does not build the example applications or require their native service dependencies. Lake maps this source directory to the existing Lean module names, so application code still uses `import LeanReact`.

`import LeanReact.Compiler` exposes `LeanReact.Compiler.options runtimeModule` and `LeanReact.Compiler.intrinsics runtimeModule`. The caller supplies the JavaScript module path as it will appear in its generated ESM. This keeps application output locations out of the engine. The example supplies that path in its [compiler configuration](../examples/lean/Examples/ReactCompiler.lean).

The root npm manifest supplies the shared JavaScript dependencies; this directory does not introduce a second toolchain or duplicate dependency installation. Workspace verification runs from root `tests/`. See the [implemented scope](../docs/IMPLEMENTED.md), [compiler ABI](LeanJS/ABI.md), and [React API](LeanReact/API.md).
