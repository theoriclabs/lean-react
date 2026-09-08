# LeanApp examples

These applications and portable domain models consume the reusable [LeanApp libraries](../engine/README.md). Start with the [café guide](../docs/GETTING_STARTED.md) for the full-stack path, or [LeanReact](../docs/LEANREACT.md) for Lean-authored components. The café's native integration currently lives in [LeanAppNative.Cafe](../adapters/native/LeanAppNative/Cafe.lean); it remains application-specific code, not a framework domain type.

| Directory | Content |
| --- | --- |
| `ordering/` | Portable ordering domain and café rules; no React/SQLite imports in the domain. |
| `cafe/` | Proof & Pour React/JavaScript UI, Lean preview bridge and private recipe client. |
| `security/` | Pure Private Notes authorization policy, scoped reads and response proofs. |
| `notes/` | Private Notes React UI and recorded agent-patch rejection evidence; [guide](../docs/PRIVATE_NOTES.md). |
| `auth/` | Focused username/password auth UI; native adapter is in `adapters/native`. |
| `lean/Examples/` | Tickets domain, contracts, components, queries, composition examples, and code generators |
| `web/` | Showcase website, browser entry point, HTML, and ordinary CSS |
| `consumer/` | Independent Node and TypeScript consumers of generated Lean modules |
| `adapters/` | Example-specific foreign React and Tickets wire/service adapters |
| `native/` | Optional local Tickets server using the sibling LeanDB and LeanHttp projects |
| `generated/` | Generated ESM, TypeScript declarations, and manifests; ignored by version control |
| `dist/` | Browser bundle and static assets; ignored by version control |

Run commands from the repository root. For the café, use `npm run build:cafe`, build `leanapp_cafe` in the native package, then `npm run dev:cafe`; the [full instructions](../docs/GETTING_STARTED.md) cover dependencies and local persistence. For the focused auth UI, see [authentication](../docs/AUTH.md).

The frontend playground uses the original commands:

```sh
npm run build
npm run dev
npm run example:consumer
```

`lake build Examples` builds the Lean example library explicitly. Its source root is `examples/lean`, so module imports retain the `Examples.*` namespace without a filesystem case collision. The browser generators write to `examples/generated/`; the bundler writes to `examples/dist/`.

The default page is the showcase with a live Lean counter and the Tickets playground. `/?example=collections#playground` runs the Lean collection editor with nested field validation; `/?example=libraries#playground` runs a provider and consumer emitted into separate libraries that import one shared context. Source excerpts are bundled directly from the corresponding Lean files. See the [composition guide](../docs/COMPOSABILITY.md) and [generator](lean/Examples/GenerateComposability.lean).

`npm run screenshots` builds the website and captures actual browser interactions for the README. Desktop images go in `docs/images/`; mobile inspection output stays under ignored `.verification/showcase/`. It uses the existing Playwright dependency and introduces no additional tooling language or package.

The [native guide](../docs/NATIVE.md) documents the optional server. Example-specific behavior and dependencies belong in this directory; reusable primitives belong in `engine/`. Root `scripts/` provides workspace build/dev/test commands.
