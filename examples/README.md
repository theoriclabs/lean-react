# LeanReact examples

All application-specific source lives here and consumes the reusable [engine](../engine/README.md).

| Directory | Content |
| --- | --- |
| `lean/Examples/` | Tickets domain, contracts, components, queries, composition examples, and code generators |
| `web/` | Showcase website, browser entry point, HTML, and ordinary CSS |
| `consumer/` | Independent Node and TypeScript consumers of generated Lean modules |
| `adapters/` | Example-specific foreign React and Tickets wire/service adapters |
| `native/` | Optional local Tickets server using the sibling LeanDB and LeanHttp projects |
| `generated/` | Generated ESM, TypeScript declarations, and manifests; ignored by version control |
| `dist/` | Browser bundle and static assets; ignored by version control |

Run commands from the repository root:

```sh
npm run build
npm run dev
npm run example:consumer
```

`lake build Examples` builds the Lean example library explicitly. Its source root is `examples/lean`, so module imports retain the `Examples.*` namespace without a filesystem case collision. The browser generators write to `examples/generated/`; the bundler writes to `examples/dist/`.

The default page is the showcase with a live Lean counter and the Tickets playground. `/?example=collections#playground` runs the Lean collection editor with nested field validation; `/?example=libraries#playground` runs a provider and consumer emitted into separate libraries that import one shared context. Source excerpts are bundled directly from the corresponding Lean files. See the [composition guide](../docs/COMPOSABILITY.md) and [generator](lean/Examples/GenerateComposability.lean).

`npm run screenshots` builds the website and captures actual browser interactions for the README. Desktop images go in `docs/images/`; mobile inspection output stays under ignored `.verification/showcase/`. It uses the existing Playwright dependency and introduces no additional tooling language or package.

The [native guide](../docs/NATIVE.md) documents the optional server. Example-specific behavior and dependencies belong in this directory; reusable primitives belong in `engine/`. Root `scripts/` provides workspace build/dev/test commands.
