# LeanReact examples

All application-specific source lives here and consumes the reusable [engine](../engine/README.md).

| Directory | Content |
| --- | --- |
| `lean/Examples/` | Tickets domain, contracts, components, queries, composition examples, and code generators |
| `web/` | Browser entry point, HTML, and ordinary CSS |
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

The [native guide](../docs/NATIVE.md) documents the optional server. Example-specific behavior and dependencies belong in this directory; reusable primitives belong in `engine/`. Root `scripts/` provides workspace build/dev/test commands.
