# LeanApp libraries

This directory contains LeanApp's portable framework libraries, including LeanReact and the LeanJS compiler. Engine Lean modules and JavaScript modules do not import example application code. [Architecture](../docs/ARCHITECTURE.md) explains the boundaries; [the documentation index](../docs/README.md) routes to application guides.

| Directory | Responsibility |
| --- | --- |
| `LeanOntology/` | Shared paths, identities, validation, descriptors, codecs, and query descriptions |
| `LeanContract/` | Typed operations, shared HTTP envelope codecs, and browser fetch transport |
| `LeanApp/` | Explicit application assembly, typed bindings, policy slots and capability interfaces |
| `LeanReact/` | Components, hooks, actions, forms, resources, and native reference behavior |
| `LeanJS/` | Lean-to-JavaScript compiler and generated value ABI |
| `runtime/` | Reusable JavaScript React/action/resource runtime |
| `adapters/` | Concrete LeanJS-to-React representation bridge |

From the repository root, `npm run build:engine` or `lake build` builds the engine, including the optional `LeanReact.Compiler` integration module. It does not build the example applications or require their native service dependencies. Lake maps this source directory to the existing Lean module names, so application code still uses `import LeanReact`.

`import LeanReact.Compiler` exposes `LeanReact.Compiler.options runtimeModule` and `LeanReact.Compiler.intrinsics runtimeModule`. The caller supplies the JavaScript module path as it will appear in its generated ESM. This keeps application output locations out of the engine. The example supplies that path in its [compiler configuration](../examples/lean/Examples/ReactCompiler.lean).

The private root npm workspace, `leanapp-workspace`, supplies shared JavaScript dependencies; this directory does not introduce a second toolchain or duplicate dependency installation. The compatible Lake package name remains `leanreact`; `import LeanApp`, `import LeanReact` and `import LeanJS` are separate module entry points. The optional [native package](../adapters/native/lakefile.lean) integrates the independent LeanDB/LeanHttp dependencies without adding them to portable builds.

Workspace verification runs from root `tests/`. See the [framework status](../docs/LEANAPP_STATUS.md), [frontend support](../docs/IMPLEMENTED.md), [compiler ABI](LeanJS/ABI.md), and [React API](LeanReact/API.md). The [contributor guide](../CONTRIBUTING.md) maps changes to test commands.

`LeanJS.Options.library` and `LeanJS.Options.libraries` define compiled library exports and imports. Shared values retain identity through ordinary ESM dependencies, and top-level values initialize before rendering. The [composition guide](../docs/COMPOSABILITY.md) describes these APIs and the collection form support.
