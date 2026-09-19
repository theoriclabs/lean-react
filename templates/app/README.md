# {{Name}}

A LeanApp application scaffolded by `leanapp new`: a shared domain rule (`{{Name}}/Domain.lean`) that
runs in the browser and on the server, two approved operations (`{{Name}}/Contracts.lean`), a LeanReact
screen (`{{Name}}/UI/App.lean`), and a native package with SQLite storage, policies, username/password
sessions and a lifecycle-managed process (`native/`). The public process is the LeanApp gateway
(`gateway/serve.mjs`).

## Build, run, test

Requirements: Lean 4.33.0 via elan, Node ≥ 22.13, a C toolchain and OpenSSL 3 development files
(Homebrew `openssl@3` on macOS). The first native build clones LeanDB, LeanHttp, leanws, LeanSQLite
and lean-react at their pinned revisions into `.lake/packages`.

```sh
npm install
npm run build
(cd native && lake build)
npm test
```

`npm run build` builds the native library, generates the browser wire client from the approved
operations (`web/generated/operations.mjs`, `.d.ts`, `manifest.json`), compiles the screen with LeanJS
(`web/generated/app.mjs`) and bundles `dist/`. `lake build` in `native/` produces the process
`native/.lake/build/bin/{{name}}_server` and `{{name}}_checks` (storage, handler and access-control checks over a
temporary database; run it after a build). `npm test` starts the process on a disposable database and
exercises authentication, the title rule, persistence across a restart and account isolation over HTTP.

```sh
npm run dev            # http://127.0.0.1:4270, database in .lake/{{name}}.sqlite
npm run test:browser   # Playwright against a disposable server on port 4272
```

Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to use an installed Chrome instead of Playwright's browser.

## Developing against a local lean-react checkout

The pins are immutable Git revisions. To build against local sources instead, set the matching
environment variables (the npm scripts turn them into Lake `-K` overrides), for example:

```sh
export LEANAPP_LEANREACT_SOURCE=/path/to/lean-react
export LEANAPP_LEANDB_SOURCE=/path/to/lean-react/adapters/native/.lake/packages/leandb   # or a LeanDB checkout
export LEANAPP_LEANHTTP_SOURCE=... LEANAPP_LEANWS_SOURCE=... LEANAPP_LEANSQLITE_SOURCE=...
npm run build && (cd native && lake -Kleanreact=$LEANAPP_LEANREACT_SOURCE -Kleanapp_native=$LEANAPP_LEANREACT_SOURCE/adapters/native build) && npm test
```

Never commit a `lake-manifest.json` that records such a path.

## Deploy

`npm run package` writes a self-contained source snapshot with a SHA-256 manifest under
`.lake/releases/`; build its `Dockerfile` from that directory. The image listens on `PORT` (8080), needs
`LEANAPP_ORIGIN` (or Railway's public domain) and a persistent `LEANAPP_DB_PATH` (or a Railway volume),
and starts Lean on loopback port 4271. See lean-react's `docs/HOSTING.md` for the operational details
(request logs, `/internal/metrics`, `LEANAPP_DB_READERS`, drain and backups).

## Layout

| Path | Purpose |
| --- | --- |
| `{{Name}}/Domain.lean` | `Title.parse`: the one rule, compiled to both targets |
| `{{Name}}/Contracts.lean` | `Note`, wire codecs, operation identities, the `NoteService` the screen consumes |
| `{{Name}}/UI/App.lean` | The LeanReact screen (`useResource`, `useForm`) |
| `Generate.lean` | LeanJS generator for the screen |
| `native/{{Name}}Native/Storage.lean` | `NoteRow` entity, tenant/actor-scoped reads and the write transaction |
| `native/{{Name}}Native/Application.lean` | Bindings with `Policy.authenticated`, read/write capabilities, the host |
| `native/Main.lean` | Auth service, host, lifecycle, environment |
| `native/Checks.lean` | Storage/handler checks including the access-control negative cases |
| `native/GenerateClient.lean` | Generated browser client and TypeScript types |
| `web/` | The React shell and the compiled screen |
| `gateway/serve.mjs` | `createGateway` configuration |
| `tests/` | One HTTP test, one Playwright test |
| `deploy/Dockerfile`, `scripts/package.mjs` | Source snapshot and container |
