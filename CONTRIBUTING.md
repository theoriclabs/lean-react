# Contributing to LeanApp

[Documentation](docs/README.md) · [Architecture](docs/ARCHITECTURE.md) · [Implementation status](docs/LEANAPP_STATUS.md)

Work on the smallest library boundary that owns the behavior. LeanApp is the overall framework; LeanReact and LeanJS remain reusable libraries within it. Keep domain examples out of engine imports, and keep LeanDB/LeanHttp changes in their independent projects.

## Development setup

Use the exact Lean version in `lean-toolchain` and Node 22.13 or newer. Install the shared JavaScript dependencies once at the repository root:

```sh
npm ci
npm run build:engine
```

The root Lake package is still named `leanreact` for compatibility. Keep module names, public operation namespaces and ABI identifiers stable unless deliberately making a reviewed breaking change. Do not replace those names during a product-copy edit.

The [getting-started guide](docs/GETTING_STARTED.md) covers the café and native source overrides. The [LeanReact guide](docs/LEANREACT.md) covers the frontend-only path. Native builds require the reviewed external source checkouts, OpenSSL 3 development files and a C toolchain.

## Choose the relevant checks

Run commands from the repository root. A docs-only edit does not require public deployment or creating accounts.

| Change | Checks |
| --- | --- |
| README, onboarding or architecture docs | `npm run test:docs` and `git diff --check`. |
| Portable framework/domain libraries | `npm run test:framework`. |
| React runtime or compiler | `npm test`, then `npm run test:browser` for browser-facing changes. |
| Native application/storage/HTTP adapters | `npm run test:framework:native`. |
| Authentication | `npm run test:auth` and `npm run test:auth:browser`. |
| Café rule, client or UI | Build the café, run `npm run test:cafe`, `node --test tests/integration/cafe-client.test.mjs`, and `npm run test:cafe:browser`. |
| Native Tickets compatibility | `npm run test:native` and `npm run test:native:http`; use the [native guide](docs/NATIVE.md) for dependency setup. |

`test:framework` includes the existing compiler/runtime/integration suite and the application/ordering gates. Native and browser profiles remain separate so a portable contributor need not install the database stack.

Framework native/auth runners accept `LEANAPP_LEANDB_SOURCE`, `LEANAPP_LEANHTTP_SOURCE`, `LEANAPP_LEANSQLITE_SOURCE`, `LEANAPP_LEANREACT_SOURCE`, and `LEANAPP_OPENSSL_SOURCE` as explicit overrides. For example:

```sh
LEANAPP_LEANSQLITE_SOURCE=/absolute/path/to/leansqlite npm run test:framework:native
```

Browser tests require a Playwright-compatible Chromium installation. If using local Chrome on macOS:

```sh
PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  npm run test:cafe:browser
```

Run suites serially when they share fixed ports. Test fixtures create their own databases; do not substitute the user's working database or hosted data. Tests requiring loopback listeners may need permission outside a restricted sandbox.

## Documentation is part of the API

Put current user guidance in `docs/`, with a route from [the index](docs/README.md). Keep the root README focused on the framework's purpose, a working entry point and limits. Detailed frontend guidance belongs under LeanReact, not under an ambiguous framework-wide support heading.

Use real source links for claims about guarantees. Distinguish a typechecked invariant, a runtime validation, finite test coverage and a future design proposal. Never infer native/browser compiler equivalence or whole-system verification from a successful example.

Mark complete, independently compilable Lean examples with `<!-- lean-check: unique-name -->` immediately before a `lean` fence. `npm run test:docs` extracts those examples into a new ignored `.lake/docs-check-*` directory and typechecks them. Deliberate failure examples must be clearly labeled and backed by an existing rejection fixture. The same command validates local file links and heading anchors in the main developer guides; it does not crawl external URLs or run every shell command in prose.

## Generated files and release boundaries

Edit Lean source and generators, not generated ESM/declarations or browser bundles. `.lake`, `examples/generated`, café generated assets and test outputs are build artifacts. Keep source snapshots and prior qualification receipts intact; a new build gets a new output directory.

The root npm workspace is private. Its name does not promise an npm package or standalone packages for every library. The existing v0.1 tag belongs to the LeanReact frontend; the planned `0.2.0-rc.1` is the LeanApp full-stack candidate. Align version fields when cutting that release, after reviewing the exact source scope and checks.

Deployment and publication are explicit actions. A documentation change does not rename the GitHub repository, deploy to Railway, publish packages or rewrite an already-recorded source/image hash. [Release evidence](docs/RELEASE.md) records the hosted snapshot; [hosting](docs/HOSTING.md) explains how to produce a new one when a deployment is intended. Retain the [MIT license](LICENSE) and dependency notices in distributed artifacts.
