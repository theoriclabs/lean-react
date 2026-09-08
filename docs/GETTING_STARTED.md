# Get started with LeanApp

[Documentation](README.md) · [Domain modeling](DOMAIN_MODELING.md) · [Architecture](ARCHITECTURE.md)

Run Proof & Pour, change its pricing rule, and see that same rule control the browser preview and the saved recipe. This guide uses the current working checkout. LeanApp's full-stack candidate is not published yet; the `v0.1` tag contains the earlier LeanReact frontend.

To try the result without installing anything, open the [hosted café](https://proof-and-pour-production.up.railway.app). It saves recipes, not real orders. Use a disposable demo password.

## Choose what to run

| Target | Requirements beyond Node and Lean | Command | Local URL |
| --- | --- | --- | --- |
| Portable framework libraries | None | `npm run build:engine` | No server |
| LeanReact frontend playground | None | `npm run dev` | `http://localhost:4173` |
| Full-stack café | Reviewed LeanDB/LeanHttp sources, SQLite source, OpenSSL 3 development files and a C toolchain | Build below, then `npm run dev:cafe` | `http://127.0.0.1:4180` |

Use Node 22.13 or newer and the exact Lean version in [lean-toolchain](../lean-toolchain), currently 4.33.0. [elan](https://github.com/leanprover/elan#installation) selects that toolchain when you run `lake` in this repository. LeanJS uses Lean compiler internals; substituting another Lean version is not a supported shortcut.

From the repository root:

```sh
npm ci
npm run build:engine
```

No LeanDB or LeanHttp dependency is needed for that build. If you only want Lean-authored React components, continue with the [LeanReact guide](LEANREACT.md).

## Prepare the native dependencies

The default native development layout is:

```text
code/
├── leanreact/       # this LeanApp checkout; the local folder can keep its name
├── leandb_v2/       # reviewed LeanDB sources, including transaction/runtime changes
└── leanhttp/        # independent LeanHttp sources
```

The native package fetches LeanSQLite at its pinned Git revision unless given a local source override. OpenSSL 3 development headers/libraries and a C toolchain must be installed. The default macOS OpenSSL prefix is `/opt/homebrew/opt/openssl@3`; the Linux container uses Debian's system package.

The [dependency contract](FULLSTACK_INTERFACES.md#source-and-dependency-identities) records reviewed baselines and overrides. Those historical commit IDs alone do not contain every later LeanDB change. There is no published, independently tested full-stack installer yet, and this workspace's LeanDB checkout has no configured remote. Do not replace it with an arbitrary repository or assume the old frontend tag includes these dependencies.

## Build and start the café

From the LeanApp repository root:

```sh
npm run build:cafe
(cd adapters/native && lake build leanapp_cafe)
npm run dev:cafe
```

Open **http://127.0.0.1:4180**, using that exact hostname. The public development process starts the Lean backend on loopback port 4181 and serves both the UI and API through port 4180. Do not start a second backend manually.

Configure a drink, give it a name and choose **Sign up to save**. Signup preserves the draft; choose **Save recipe** once your account is ready. Open **Saved recipes**, refresh the page, and log out/in to exercise session restoration. Each account has a private collection capped at 40 recipes.

The default database is `.lake/cafe.sqlite`. Stop with Ctrl-C; the database remains for your next run. Rebuild and restart after source edits: the café launcher is not a hot-reload development server.

### Source and OpenSSL overrides

For an offline build using the SQLite source already present in the reviewed LeanDB checkout:

```sh
(cd adapters/native && \
  lake -Kleansqlite=../../../leandb_v2/.lake/packages/leansqlite build leanapp_cafe)
```

This is an explicit source override, not a dependency on precompiled artifacts. If your checkouts live elsewhere, pass absolute paths before `build`:

```sh
lake -Kleanreact=/absolute/path/to/this-checkout \
  -Kleandb=/absolute/path/to/leandb_v2 \
  -Kleanhttp=/absolute/path/to/leanhttp \
  -Kleansqlite=/absolute/path/to/leansqlite \
  -Kopenssl=/absolute/openssl-prefix build leanapp_cafe
```

Run that command from `adapters/native`, replacing the example paths. Keep the key `leanreact`: it is the compatible Lake dependency name even though the framework is called LeanApp.

## Change a rule once

Open [Cafe/Model.lean](../examples/ordering/Cafe/Model.lean). `Cafe.rule` defines a base price of 450 USD cents and exact signed option adjustments. For example, changing the oat adjustment from 75 to 100 adds 25 cents to every oat drink.

Rebuild both targets and restart the café with the commands above. The browser preview and the native save operation now evaluate the new rule. Existing saved recipes store their configuration, not a locked historical quote; their displayed price is recomputed under the current rule.

Availability lives in the shared [configuration model](../examples/ordering/Ordering/Domain/Configuration.lean). The UI tries each candidate choice through `Cafe.preview` and disables candidates that fail. The native save handler checks the submitted configuration independently of the browser.

Tests contain independent price expectations. If you deliberately change the rule, update those expectations as part of the same change; a failing price assertion is useful evidence that the rule's observable behavior changed.

## Follow the application through the code

| File | What to inspect |
| --- | --- |
| [Cafe/Model.lean](../examples/ordering/Cafe/Model.lean) | Pure pricing, draft reconstruction and browser entry point. |
| [GenerateCafe.lean](../scripts/GenerateCafe.lean) and [domain.mjs](../examples/cafe/domain.mjs) | Compile the model and adapt its generated value representation. |
| [main.mjs](../examples/cafe/main.mjs) | Ordinary React UI, previews and disabled choices. |
| [LeanAppNative/Cafe.lean](../adapters/native/LeanAppNative/Cafe.lean) | Approved operations, account-scoped reads and transactional saves. |
| [CafeMain.lean](../adapters/native/CafeMain.lean) and [serve-cafe.mjs](../scripts/serve-cafe.mjs) | Native runtime, public gateway and process lifecycle. |

For a first domain of your own, work through [domain modeling](DOMAIN_MODELING.md). There is no `leanapp new` generator yet; adding a library and explicit adapters is the current authoring path.

## Check your changes

```sh
npm run test:docs
npm run test:cafe
npm run test:cafe:browser
```

Build the café first. The café API tests use disposable local databases; the browser tests start their own server on ports 4182/4183. They do not touch the hosted app or your `.lake/cafe.sqlite` database. Use an installed Chrome with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` if Playwright's browser is absent; see [contributing](../CONTRIBUTING.md).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Missing `LeanDb` or a native dependency | Confirm source paths and required local changes; use the explicit Lake overrides above. |
| `openssl/evp.h` or `-lcrypto` missing | Install OpenSSL 3 development files and supply the correct `-Kopenssl` prefix. |
| Missing `examples/dist-cafe` or `leanapp_cafe` | Run both build commands before starting. |
| Port already in use | Stop only your existing café process, or set distinct `PORT` and `LEANAPP_BACKEND_PORT` values. |
| Auth requests rejected | Use `127.0.0.1:4180`, not `localhost:4180`; origin matching is exact. |
| Production launch requires an origin or storage | `dev:cafe` explicitly enables local mode. Public hosting requires HTTPS and persistent storage; do not enable development mode there. |

Deployment is a separate step. [Hosting](HOSTING.md) explains the source snapshot and Railway settings, including the SQLite volume. A successful local build does not publish or redeploy the app.
