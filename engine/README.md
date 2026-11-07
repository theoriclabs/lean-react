# LeanReact libraries

This directory contains the UI libraries and the LeanJS compiler. Engine code does not import examples. Server routing, authentication and persistence belong in [LeanAPI](https://github.com/theoriclabs/leanapi).

| Directory | Responsibility |
| --- | --- |
| `LeanReact/` | Components, hooks, actions, forms, resources, routing, typed-endpoint UI, and native reference behavior |
| `LeanJS/` | Lean-to-JavaScript compiler and generated value ABI |
| `runtime/` | JavaScript React/action/resource runtime |
| `adapters/` | LeanJS-to-React and client transport bridges |

LeanOntology, LeanContract and the portable LeanAPI/LeanDB model types come from pinned Lake packages. `lake build` builds the libraries; `lake build Examples` builds UI examples separately. Neither builds a native server.

`import LeanReact.Compiler` exposes `LeanReact.Compiler.options runtimeModule` and `intrinsics runtimeModule`. Supply the JavaScript module path relative to generated ESM; the [example compiler configuration](../examples/lean/Examples/ReactCompiler.lean) shows this boundary.

The root npm package and Lake package are both named `leanreact`. See the [frontend support](../docs/IMPLEMENTED.md), [compiler ABI](LeanJS/ABI.md), [React API](LeanReact/API.md), and [development guide](../docs/HOW_TO.md#check-and-debug-your-work). The [composition guide](../docs/COMPOSABILITY.md) covers separately compiled libraries and shared context identity.
