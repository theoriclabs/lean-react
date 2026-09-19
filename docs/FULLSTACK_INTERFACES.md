# LeanApp interface contract

[Documentation](README.md) · [Architecture](ARCHITECTURE.md)

LeanApp is developed in this monorepo alongside its LeanReact frontend library and LeanJS compiler. The root Lake package remains `leanreact` for compatibility. LeanDB and LeanHttp are independent dependencies; their baseline entries below are not new internal monorepo packages.

LeanApp keeps the domain and operation contracts in the portable root package. SQLite, outbound HTTP, and the server belong to the optional `adapters/native` package. A browser-only consumer does not need to build that package.

This is the implementation contract for application assembly. Passing a local fixture does not qualify a production deployment.

## Source and dependency identities

The reviewed baseline uses Lean 4.33.0, compiler commit `d8b18978322de05a8f3dba51ef03cf5461676c17`. Keep the root and native `lean-toolchain` files in sync. LeanJS uses internal compiler APIs, so a toolchain upgrade requires its parity and rejection tests.

| Dependency | Pinned source | Override |
| --- | --- | --- |
| LeanReact | This repository (`../..` from the native packages) | `-Kleanreact=PATH` |
| LeanDB | `https://github.com/theoriclabs/LeanDB` at `v0.4.0` (`65b7b9236ee11dce6f9cd6417e118cff6cbcedac`) | `-Kleandb=PATH` |
| LeanHttp | `https://github.com/theoriclabs/leanhttp` at `v0.3.1` (`9adb3d6535a5e3c46cb2dff8a1000db2449aa207`) | `-Kleanhttp=PATH` |
| leanws | `https://github.com/theoriclabs/leanws` at `40900ccb00e04186360ba0a235c560517b7ecb57` (v0.1.0 plus `Handshake.Reject.unauthorized`) | `-Kleanws=PATH` |
| LeanSQLite | `https://github.com/leanprover/leansqlite` at `0be4df908d1a8e75b58961041e2b4973692623df` | `-Kleansqlite=PATH` |

Both native packages (`adapters/native` and `examples/native`, which shares the adapter's `.lake/packages` directory) record these revisions in their `lake-manifest.json`, so a fresh clone builds with no sibling checkouts. `npm run test:manifest` (part of `npm test`) refuses any manifest entry that is not a commit-pinned GitHub source or a path inside this repository. A `-K` override is for local development against a modified dependency; never commit a manifest that records such a path. The deployment snapshots (`npm run package:cafe`, `package:notes`) copy the fetched sources from `adapters/native/.lake/packages` and their Dockerfiles pass the same overrides so the container never reaches the network.

The native runtime the adapter consumes is LeanDB 0.4.0's `Runtime.Service` (LDB-01) wrapped by `LeanAppNative.Runtime`, which adds the bounded writer queue, typed admission errors, an exclusive read-only connection pool (LDB-09, `LEANAPP_DB_READERS`) and a dedicated snapshot connection for backups.

## Portable sources and publication

`engine/LeanOntology` contains identity, validation, descriptors and wire codecs. `engine/LeanContract` contains typed operations and checked router erasure. `engine/LeanApp` assembles explicitly approved exports and validates their bindings. Domain examples live under `examples/lean` and `examples/ordering`; native mappings live under `adapters/native`.

An operation retains its input, output, error and execution kind until `Contract.Route.ofHandler`. A public manifest lists approved operations and their public codecs. Importing a module or describing a field does not publish a table or grant mutation rights. A trusted context constructor is an adapter boundary; it is not an authentication provider or a sandbox for arbitrary Lean code.

## Three representations

LeanJS ABI v0 uses tagged constructors, `bigint` natural/integer values and erased proof slots. The complete contract is in [ABI.md](../engine/LeanJS/ABI.md). JavaScript callers must use the generated arities and value representation; a Lean constructor object is not wire JSON.

Wire natural numbers use tagged canonical decimal strings. Public IDs retain their nominal entity type and checked scope/key. Operation identity is the exact namespace/name/version tuple. Incompatible versions fail before a handler runs; neither transport nor storage silently upgrades them.

SQLite INTEGER is signed 64-bit. `LeanAppNative.Storage.SqlNat` checks that range before encoding. `ExactNat` uses canonical decimal TEXT and deliberately has no SQL numeric-ordering capability. A mapping checks reconstruction; a public ID still needs indexed row resolution and current access policy.

## Generated client

`LeanContract.Generate.emitClient ops codecs statuses out` writes a browser client from the public manifest: `operations.mjs` (one `defineHttpOperation` object per approved operation, codecs derived from each `WireSchema`, `createClient`), `operations.d.ts`/`.d.mts` (input, output and error types plus a typed `call` overload per operation identity) and `manifest.json` (the exact `/api/manifest` body; `createClient({ verify: true })` fetches the served manifest before the first request and fails with `incompatible` / `contract.stale_manifest` when it differs). Derived shapes: records with exact key sets, tagged variants, `nat`/`int` as canonical decimal strings ↔ `bigint` (never `Number`), `Option` as `{tag:"none"}`/`{tag:"some",value}`, arrays, products as pairs, maps as pair arrays with duplicate keys rejected, and `entity-id/1` named records with their nominal type checked. Domain errors decode to tagged objects and `errorStatus` mirrors the Lean policy; declare tag-decided statuses with `ErrorStatus.ofTags` so the table can be read without decoding a payload.

The generated client is a shape check, not the domain parser. A codec whose `decode` validates beyond its schema (a title length, a status name) is still validated on the server, and a LeanJS consumer converts wire values with the compiled parsers ([tickets-service.mjs](../examples/adapters/tickets-service.mjs)). Named scalar schemas carry no regex or length descriptors yet, so those codecs accept any string. Generated files are committed ([Tickets](../examples/adapters/tickets-client), [café](../examples/cafe/wire)) and regenerated by `npm run build` (`examples/lean/Examples/GenerateClient.lean`) and `cd adapters/native && lake env lean --run GenerateCafeClient.lean`; `tests/integration/generated-client.test.mjs` and `tests/cafe/wire.test.mjs` regenerate into a scratch directory and diff, and the Lean fixtures from `tests/integration/ClientFixtures.lean` must decode and re-encode identically after canonical key ordering. `examples/consumer/typescript.tsx` type-checks against the declarations.
## Public manifest and the gateway

`GET /api/manifest` returns `{"operations": [...]}`. Each entry carries the operation identity and codecs, and, once the native server emits them, `http` and `metadata`:

```json
{"namespace": "cafe", "name": "save", "version": "1", "kind": "command", "input": {}, "output": {}, "error": {},
 "http": {"path": "/api/recipes/save", "method": "POST", "maxBodyBytes": null},
 "metadata": {"title": "", "description": "", "publish": null, "issuesStreamTicket": false}}
```

The Node gateway reads this manifest at startup. `http.path` (a literal path per `HttpBinding.validate`) joins the route allowlist and `http.maxBodyBytes` overrides the gateway's body cap for that path; operations without `http` are covered by the gateway's `routes.extra`. `metadata.publish`, when present, is `{"topicField", "topicPrefix", "eventName", "alsoToActorField"}`: after a proxied HTTP 200 `success` reply the gateway publishes the reply `value` as an SSE event named `eventName` to topic `<topicPrefix>:<value[topicField]>` and, when `alsoToActorField` is set, to `user:<value[alsoToActorField]>`. `metadata.issuesStreamTicket: true` marks a command whose success value is `{"ticket", "expiresAt", "topics"}`; the gateway records the ticket for `GET /stream?ticket=…`. `expiresAt` is an ISO-8601 string or an epoch value (seconds or milliseconds). See [Live events](ARCHITECTURE.md#live-events) for the trust boundary and [Hosting](HOSTING.md#gateway-module) for the gateway configuration.

## Tickets compatibility fixture

The baseline contract is [Examples.Tickets.Contracts](../examples/lean/Examples/Tickets/Contracts.lean). Its public paths are `GET /api/manifest`, `POST /api/tickets/list`, and `POST /api/tickets/save`. Requests contain `operation`, `kind` and `input`. Replies preserve success, domain error, decode error, protocol error and incompatibility as distinct outcomes. Native and browser clients decode declared domain errors even on non-2xx responses.

The generic HTTP integration must pass existing fixtures in `tests/native`, `tests/integration/wire.test.mjs`, and the native browser tests before replacing those adapters. The local Tickets policy is a fixture role table behind `Policy.requireRole` (owner/editor/viewer per tenant actor), checked by the ACL matrix in `tickets_checks`; it is not authentication.
