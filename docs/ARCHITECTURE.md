# LeanApp architecture

[Documentation](README.md) · [Domain modeling](DOMAIN_MODELING.md) · [Interface contract](FULLSTACK_INTERFACES.md)

The domain model owns application meaning. React presents it, storage persists selected representations, and HTTP carries approved operations. LeanApp assembles those pieces without requiring domain types to inherit from a framework class or mirror a database table.

## Names and compatibility

LeanApp is the product and framework developed in this monorepo. LeanReact is its frontend library, and LeanJS is its compiler for the supported Lean-to-JavaScript subset. LeanDB and LeanHttp remain independent libraries maintained outside this repository.

| Name | Meaning and compatibility decision |
| --- | --- |
| LeanApp | Overall framework/product; portable module namespace `LeanApp`. |
| LeanReact | Frontend library; `import LeanReact` and `LeanReact.Compiler` remain unchanged. |
| LeanJS | Compiler and generated-value ABI; `import LeanJS` remains unchanged. |
| `leanapp-workspace` | Private root npm workspace, with shared dependencies and development commands. It is not an installable framework release. |
| `leanreact` | Existing root Lake package name. Retained so native requirements and `-Kleanreact=PATH` keep working. |
| `theoriclabs/lean-react` | Existing GitHub repository URL. No second repository or remote rename is needed for this transition. |

Wire namespaces such as `leanreact.tickets`, ABI identifiers and existing source paths are compatibility surfaces. Do not mechanically replace them with `leanapp`. Renaming a public protocol is a versioned protocol change, not branding work.

The libraries share a checkout and coordinated tests while their interfaces evolve. A monorepo does not mean every consumer must import or build every library. It also does not mean each module already has an independently published package.

## Source boundaries

```text
LeanApp repository
├── engine/
│   ├── LeanApp/          application assembly, policies, capabilities
│   ├── LeanOntology/     identities, validation, descriptions, codecs
│   ├── LeanContract/     typed operations and shared transports
│   ├── LeanReact/        components, hooks, forms
│   ├── LeanJS/           compiler and generated ABI
│   ├── runtime/          JavaScript React/action/resource runtime
│   └── adapters/         generated Lean values ↔ React
├── adapters/native/     optional LeanDB/HTTP/auth integration
├── examples/            application models, UIs and application-specific adapters
├── tests/               portable, native and browser checks
├── scripts/             shared build/test/packaging commands
└── deploy/cafe/          café container

Independent dependencies
├── LeanDB               typed SQLite persistence and instance runtime
├── LeanHttp             outbound native HTTP over libcurl
└── LeanSQLite           SQLite binding used by native storage
```

Reusable engine modules do not import example applications. The root portable build does not depend on native SQLite or OpenSSL. The optional native Lake package depends on the portable package and independent native libraries. Domain-specific recipe code is an example integration, even where the current native build keeps it under `LeanAppNative.Cafe`.

The source snapshot for deployment copies an allowlisted subset of independent dependency sources. That is a build input bundle with retained licenses, not a transfer of those projects into this monorepo or a separately maintained fork.

## Typed operations become explicit exports

`Contract.Operation kind Input Output Error` retains the operation's input, output, error and execution kind. A `LeanApp.Binding` adds a policy and handler, plus an HTTP binding. The policy has no implicit allow-all default.

Query handlers receive `ReadCapability`; command handlers receive `CommandCapability`, which adds writes. The selected operation families define what those capabilities mean. Their interpreters are trusted host code: a read interpreter must actually be read-only. A command capability does not automatically wrap a transaction around arbitrary handler code.

`Binding.approve` explicitly publishes an operation. A `Module` collects approved exports and storage claims. `Application.create` checks the assembled registry for duplicate identities/paths, missing module dependencies and conflicting physical-table mappings. Module dependencies require presence; they do not prescribe initialization order.

Importing a module does not publish its tables. The public manifest describes approved operations and codecs, not private storage/admin APIs. HTTP dispatch checks that both the literal path and the wire operation identity select the same approved operation.

See [Binding.lean](../engine/LeanApp/Binding.lean), [Application.lean](../engine/LeanApp/Application.lean) and the [in-memory fixture](../tests/app/Main.lean). The native café uses the approved registry and auth host; it does not claim every future application-host feature is integrated.

## A request through the café

```text
Cafe model ── LeanJS ── browser preview and available choices
    │
    └── native Lean compilation ── authoritative save check

Browser
  → HTTPS ingress
  → Node gateway: assets, origin/body/admission limits
  → loopback Std.Http.Server
  → auth host: current session, CSRF and approved operation
  → handler: checked input, domain rule, explicit transaction
  → LeanDB / SQLite on the persistent volume
```

The café's public process serves ordinary React/JavaScript and proxies only approved auth/recipe routes. Its native listener is loopback-only. Hosting providers terminate public TLS; the configured origin is trusted configuration, not a value inferred from incoming Host headers.

Auth resolves current account/session authority under the runtime's owned connection callback. Recipe queries are scoped by actor and tenant. Saves compute the price on the server and check the 40-recipe limit within the write transaction. Deletes include the same ownership constraints; knowing another recipe's ID grants no access.

LeanHttp supplies outbound clients, not this inbound listener. `Std.Http.Server` handles inbound native HTTP. React can be authored in JavaScript, as in the café, or in Lean through LeanReact, as in the frontend playground.

## Live events

Lean-native WebSocket channels are the primary real-time path; the gateway pipes those upgrades to Lean byte for byte and holds no session state. For environments that block WebSockets, and for one-way feeds, the gateway offers a Server-Sent Events fallback in [engine/gateway/events.mjs](../engine/gateway/events.mjs). Its trust boundary is deliberately narrow:

- What gets published is declared in Lean. An approved operation's `metadata.publish` names the success-value field that selects the topic, the topic prefix and the SSE event name. The gateway re-broadcasts only Lean's own HTTP 200 `success` reply values; domain errors, failures and unannotated operations publish nothing.
- Who may listen is decided in Lean. An ordinary approved command marked `issuesStreamTicket` runs the real access check in its policy and returns `{ticket, expiresAt, topics}`. The gateway records that ticket bound to a hash of the caller's session cookie; `GET /stream?ticket=…` needs the same cookie and an unexpired ticket. The gateway mints no authority and never inspects cookie values beyond hashing them.
- Nothing is replayed. The gateway keeps no history: a reconnecting client receives `hello` with its `Last-Event-ID` and gap-fills through its own Lean query. Under backpressure the per-stream queue drops droppable events oldest first and closes the stream rather than dropping an `ops` event, so a client that fell behind knows to resynchronise.

Limits (`maxStreams`, `maxStreamsPerCookie`, `maxTopicsPerTicket`) and counters live in the gateway; apps whose manifest declares neither publishers nor ticket issuers get no `/stream` route at all. The presence relay described in the original design is not implemented: presence travels over channels as typed inbound messages.

## Application state

`AppState σ` is the sanctioned slot for memory that outlives a request (a hot cache, a rate-limit table, a topic registry). It is created once, passed into the factory, and must never contain a `Conn`.

1. **Restore / re-open.** `Managed.restored` runs `onInvalidate` (default: reset to `initial`) before the next admitted request.
2. **Drain / close.** `Managed.shutdown` runs `onDrain` under the writer, then stops admission. Nothing is persisted implicitly.
3. **Coherence.** Mutate state from a write after the transaction commits: `AppState.afterCommit` plus `AppState.transaction`. Hooks do not run when the body aborts.
4. **Concurrency.** `AppState` operations are atomic `IO.Ref` updates; larger invariants rely on the writer.

## Channels

Typed bidirectional operations (`LeanContract.Channel`) live in Lean. Subscribe policy yields evidence the inbound handler cannot invent. `Channels.Registry` fans events out in memory; `publish` never touches the database. The Node gateway (`LA-15`) is a byte pipe for `/ws` after Origin/cookie/subprotocol gates. `useChannel` / `channels.mjs` keep one multiplexed socket per origin; `useStream` is the SSE fallback.

## Keep three representations separate

| Representation | Boundary rule |
| --- | --- |
| Lean domain values and generated LeanJS values | The generated ABI uses tagged constructors and exact `bigint` integers; proof slots are erased. JavaScript can forge object shapes, so this is not an untrusted-input validator. |
| Wire JSON | Explicit codecs check public shapes and operation identity/version. The generic contract integer codec and café's small primitive bridge have their own documented representations. |
| SQLite rows | Mappings check reconstruction and integer ranges; physical IDs and public IDs have different roles. Raw storage access does not bypass domain/access policy through a public API. |

The [interface contract](FULLSTACK_INTERFACES.md#three-representations) and [LeanJS ABI](../engine/LeanJS/ABI.md) specify the details. Shared Lean source reduces duplicate business logic; it does not eliminate representation conversion or runtime validation.

## What is qualified

The hosted café has native/browser model parity, real HTTP isolation checks and public Chrome workflows. Its Linux amd64 Railway image passed readiness and retained sessions/recipes through a real restart. This is a bounded deployed application, not proof of a general production framework.

The ordering library also models revision-bound quotes, inventory and typed payment/cancellation states. It is a portable reference model; the café persists recipes rather than implementing that full ordering workflow.

Durable command receipts, outbox delivery and schema evolution/restore qualification remain unfinished. Application-host drain is `Lifecycle.shutdown`; `scripts/new-app.mjs` scaffolds a standalone repo. Native FFI, cryptography, the JavaScript compiler/runtime and hosting are trust boundaries. [Release evidence](RELEASE.md) names the deployed artifact rather than assuming the current dirty checkout is identical to it.
