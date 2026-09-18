# LeanApp interface contract

[Documentation](README.md) · [Architecture](ARCHITECTURE.md)

LeanApp is developed in this monorepo alongside its LeanReact frontend library and LeanJS compiler. The root Lake package remains `leanreact` for compatibility. LeanDB and LeanHttp are independent dependencies; their baseline entries below are not new internal monorepo packages.

LeanApp keeps the domain and operation contracts in the portable root package. SQLite, outbound HTTP, and the server belong to the optional `adapters/native` package. A browser-only consumer does not need to build that package.

This is the implementation contract for application assembly. Passing a local fixture does not qualify a production deployment.

## Source and dependency identities

The reviewed baseline uses Lean 4.33.0, compiler commit `d8b18978322de05a8f3dba51ef03cf5461676c17`. Keep the root and native `lean-toolchain` files in sync. LeanJS uses internal compiler APIs, so a toolchain upgrade requires its parity and rejection tests.

| Dependency | Reviewed source | Development location |
| --- | --- | --- |
| LeanReact | `d56cf1896776b88c3d36241a05759a0d16bfaf53` | This repository |
| LeanDB | `f01db4837a18f13bed8c22af5be831d42eafbcc8` | `../leandb_v2` |
| LeanHttp | `9adb3d6535a5e3c46cb2dff8a1000db2449aa207` | `../leanhttp` |
| LeanSQLite | `0be4df908d1a8e75b58961041e2b4973692623df` | Lake Git dependency |

These identify the baseline, not a released version containing the new framework. LeanDB has no configured Git remote in this workspace. A clean external release needs an approved immutable source URL or a checksummed source bundle for it; do not invent a repository URL or claim that the baseline contains later transaction changes.

The native Lake file accepts explicit `-Kleanreact=PATH`, `-Kleandb=PATH`, `-Kleanhttp=PATH`, and `-Kleansqlite=PATH` source overrides. The first three default to the development checkouts. SQLite defaults to its immutable Git revision. There are no implicit paths into another checkout's `.lake` directory. An explicit SQLite source override can reuse an existing local source package for offline development; that check is not evidence of a cold-cache release build.

## Portable sources and publication

`engine/LeanOntology` contains identity, validation, descriptors and wire codecs. `engine/LeanContract` contains typed operations and checked router erasure. `engine/LeanApp` assembles explicitly approved exports and validates their bindings. Domain examples live under `examples/lean` and `examples/ordering`; native mappings live under `adapters/native`.

An operation retains its input, output, error and execution kind until `Contract.Route.ofHandler`. A public manifest lists approved operations and their public codecs. Importing a module or describing a field does not publish a table or grant mutation rights. A trusted context constructor is an adapter boundary; it is not an authentication provider or a sandbox for arbitrary Lean code.

## Three representations

LeanJS ABI v0 uses tagged constructors, `bigint` natural/integer values and erased proof slots. The complete contract is in [ABI.md](../engine/LeanJS/ABI.md). JavaScript callers must use the generated arities and value representation; a Lean constructor object is not wire JSON.

Wire natural numbers use tagged canonical decimal strings. Public IDs retain their nominal entity type and checked scope/key. Operation identity is the exact namespace/name/version tuple. Incompatible versions fail before a handler runs; neither transport nor storage silently upgrades them.

SQLite INTEGER is signed 64-bit. `LeanAppNative.Storage.SqlNat` checks that range before encoding. `ExactNat` uses canonical decimal TEXT and deliberately has no SQL numeric-ordering capability. A mapping checks reconstruction; a public ID still needs indexed row resolution and current access policy.

## Tickets compatibility fixture

The baseline contract is [Examples.Tickets.Contracts](../examples/lean/Examples/Tickets/Contracts.lean). Its public paths are `GET /api/manifest`, `POST /api/tickets/list`, and `POST /api/tickets/save`. Requests contain `operation`, `kind` and `input`. Replies preserve success, domain error, decode error, protocol error and incompatibility as distinct outcomes. Native and browser clients decode declared domain errors even on non-2xx responses.

The generic HTTP integration must pass existing fixtures in `tests/native`, `tests/integration/wire.test.mjs`, and the native browser tests before replacing those adapters. The local Tickets policy is a fixture role table behind `Policy.requireRole` (owner/editor/viewer per tenant actor), checked by the ACL matrix in `tickets_checks`; it is not authentication.
