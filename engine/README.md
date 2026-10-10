# LeanReact engine

This directory contains LeanReact's portable libraries: the UI library, its domain and server bridges to LeanAPI, and the LeanJS compiler. Engine Lean modules and JavaScript modules do not import example application code. [Architecture](../docs/ARCHITECTURE.md) explains the boundaries; [the documentation index](../docs/README.md) routes to application guides.

| Directory | Responsibility |
| --- | --- |
| `LeanReact/` | Components, hooks, actions, forms, resources, and native reference behavior; `LeanReact/Domain` (pages over typed endpoints) and `LeanReact/Server` (`app%`, full-stack serving) bridge to LeanAPI |
| `LeanJS/` | Lean-to-JavaScript compiler and generated value ABI |
| `runtime/` | Reusable JavaScript React/action/resource runtime |
| `adapters/` | Concrete LeanJS-to-React representation bridge |

The ontology (`LeanOntology`), the contracts (`LeanContract`) and the application assembly (formerly `LeanApp`, now `LeanApi.Publication`) moved to the leanontology and LeanAPI packages in milestone 3; the root lakefile requires them at pinned revisions.

From the repository root, `npm run build:engine` or `lake build` builds the engine, including the optional `LeanReact.Compiler` integration module. It does not build the example applications or require their native service dependencies. Lake maps this source directory to the existing Lean module names, so application code still uses `import LeanReact`.

`import LeanReact.Compiler` exposes `LeanReact.Compiler.options runtimeModule` and `LeanReact.Compiler.intrinsics runtimeModule`. The caller supplies the JavaScript module path as it will appear in its generated ESM. This keeps application output locations out of the engine. The example supplies that path in its [compiler configuration](../examples/lean/Examples/ReactCompiler.lean).

The private root npm workspace, `leanreact-workspace`, supplies shared JavaScript dependencies; this directory does not introduce a second toolchain or duplicate dependency installation. The Lake package name is `leanreact`; `import LeanReact`, `import LeanReact.Domain`, `import LeanReact.Server` and `import LeanJS` are separate module entry points. The optional [native package](../adapters/native/lakefile.lean) integrates the independent LeanDB/LeanHttp dependencies without adding them to portable builds.

Workspace verification runs from root `tests/`. See the [frontend support](../docs/IMPLEMENTED.md), [compiler ABI](LeanJS/ABI.md), and [React API](LeanReact/API.md). The [check-and-debug guide](../docs/HOW_TO.md#check-and-debug-your-work) maps changes to test commands.

`LeanJS.Options.library` and `LeanJS.Options.libraries` define compiled library exports and imports. Shared values retain identity through ordinary ESM dependencies, and top-level values initialize before rendering. The [composition guide](../docs/COMPOSABILITY.md) describes these APIs and the collection form support.
