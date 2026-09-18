# Native Tickets adapter

[Documentation](README.md) · [LeanApp architecture](ARCHITECTURE.md) · [Hosted café setup](HOSTING.md)

This guide is for the local Tickets compatibility fixture. For LeanApp's authenticated full-stack app, start with [getting started](GETTING_STARTED.md) and [authentication](AUTH.md). The Tickets protocol and its `leanreact.tickets` namespace remain unchanged by the LeanApp product name.

Tickets now uses the reusable LeanApp registry and optional native HTTP adapter.
[Release evidence](RELEASE.md) records the hosted café qualification.
The local fixture still has no production authentication.

The optional package in `examples/native` implements the shared
[`Examples.Tickets.Domain`](../examples/lean/Examples/Tickets/Domain.lean) using real LeanDB
SQLite persistence, a Lean `Std.Http` server, and a LeanHttp client. The portable
[`Examples.Tickets.Contracts`](../examples/lean/Examples/Tickets/Contracts.lean) imports only
the shared domain and `LeanContract`; it has no native dependencies.

## Build and run

Run from the repository root with the installed **Lean 4.33.0** toolchain:

```sh
bash examples/native/build-cached.sh
bash tests/native/check.sh --no-build
```

The cached build compiles shared source and native modules into
`examples/native/.lake/cached`, then links against the siblings' existing Lean
objects and real SQLite/LeanHttp FFI libraries. It performs no downloads, does
not invoke sibling builds, and writes neither root nor sibling build artifacts.
It explicitly sets Lean module/package identities to avoid the case-insensitive
macOS `Examples`/`examples` native-initializer mismatch.

Four executables are produced:

```text
examples/native/.lake/cached/bin/tickets_server
examples/native/.lake/cached/bin/tickets_protocol
examples/native/.lake/cached/bin/tickets_checks
examples/native/.lake/cached/bin/tickets_http_checks
```

Start the local server on port 8081 with persistent storage:

```sh
examples/native/.lake/cached/bin/tickets_server 8081 /tmp/leanreact-tickets.sqlite
```

The positional arguments are **port, SQLite file path**. Port `0` requests an
available port. The server binds `127.0.0.1` and writes one JSON readiness event
to stderr after binding, for example:

```json
{"event":"tickets.ready","host":"127.0.0.1","port":8081}
```

A fresh database is seeded from the shared domain's three example tickets.
An existing database retains its records and revisions. A nonempty ticket
table is never reseeded. No credentials or environment variables are needed.
The browser development server should proxy `/api` to this listener so the
browser can use same-origin requests; CORS and browser authentication are not
implemented by this local fixture adapter.

Print the explicit public manifest without starting a server or opening SQLite:

```sh
examples/native/.lake/cached/bin/tickets_server --manifest
```

The local Lake package also declares path dependencies on `../..`,
`../../../leandb_v2`, `../../../leanhttp`, and the cached SQLite package at
`../../../leandb_v2/.lake/packages/leansqlite`. Its manifest contains only local
path entries. If a cached object is missing or a parent wants Lake to rebuild
dependencies, the exact parent-run command is:

```sh
cd examples/native
lake --no-cache build
```

That alternative can write generated files in the root and sibling `.lake`
directories; the cached build is the verified path for this worker's ownership
envelope. No escalation or dependency download was needed for the cached build.
The standard Lake build emits executables in `examples/native/.lake/build/bin`.

Inspected sibling versions/HEADs:

| Dependency | Version / inspected HEAD |
| --- | --- |
| LeanDB | 0.3.0 / `f01db4837a18f13bed8c22af5be831d42eafbcc8` plus local FS03 transaction and FS08 runtime callback patches |
| LeanHttp | 0.3.1 / `9adb3d6535a5e3c46cb2dff8a1000db2449aa207` |
| leansqlite | 0.1.0 / `0be4df908d1a8e75b58961041e2b4973692623df` |

Local path dependencies are mutable; those HEADs are provenance, not immutable
package pins. The cached build consumes the existing sibling `.olean` and
native object artifacts without rebuilding or altering their repositories.

## Public contracts and routes

Use `open Examples.Tickets.Contracts`. The public assembly function is:

```lean
publicOperations : Ontology.Validation PublicOperations
```

`PublicOperations` has:

```lean
codecs : PublicCodecs
list : Contract.Operation .query Unit (Array TicketSummary) Unit
save : Contract.Operation .command SaveTicket TicketSummary SaveError
```

`PublicCodecs` exposes `ticket`, `summary`, `saveInput`, `saveError`,
`operationId`, and `errors`. The explicit scalar codecs `titleCodec`,
`statusCodec`, `ticketIdCodec`, and `userIdCodec` are also exported.
There are no competing global codec instances. `PublicOperations.approved`
lists the public HTTP bindings and metadata (`describePolicy` per operation);
`PublicOperations.manifest` is the standard `/api/manifest` body, one entry per
operation with its schemas, `http` (`path`, `method`, `maxBodyBytes`) and
`metadata` (`title`, `description`, `describePolicy`, `publish`, `issuesStreamTicket`).

Stable operation namespace: **`leanreact.tickets`**. Operation names:
**`list`**, **`save`**. Contract version: **`1`**.

| Route | Input | Successful output |
| --- | --- | --- |
| `POST /api/tickets/list` | Versioned query envelope with `input: null` | Array of `TicketSummary` |
| `POST /api/tickets/save` | Versioned command envelope with `SaveTicket` input | Updated `TicketSummary` |
| `GET /api/manifest` | No body | Unwrapped public manifest |

Only those routes exist. There is no `/rpc`, `/api/call`, generic DB argv
dispatcher, arbitrary SQL, administrative route, migration route, or public
fixture-initialization operation. Method mismatch is 405. Unknown route is 404.

List request:

```json
{
  "operation": {"namespace":"leanreact.tickets","name":"list","version":"1"},
  "kind": "query",
  "input": null
}
```

Save request:

```json
{
  "operation": {"namespace":"leanreact.tickets","name":"save","version":"1"},
  "kind": "command",
  "input": {
    "id": {
      "type": {"package":"leanreact.tickets","name":"Ticket"},
      "scope": "tickets-demo",
      "key": "1"
    },
    "expectedRevision": {"tag":"nat","value":"1"},
    "title": "A revised ticket title",
    "status": "inProgress"
  }
}
```

Allowed statuses are exactly `backlog`, `inProgress`, and `done`. Titles use
the shared `Title.parse`: nonempty and at most 200 Lean characters; no trimming
is added by the adapter. Unknown/missing input fields and wrong nominal IDs
are rejected by the explicit codecs.

Success, HTTP 200:

```json
{
  "operation": {"namespace":"leanreact.tickets","name":"save","version":"1"},
  "tag": "success",
  "value": {
    "id": {
      "type": {"package":"leanreact.tickets","name":"Ticket"},
      "scope":"tickets-demo",
      "key":"1"
    },
    "revision": {"tag":"nat","value":"2"},
    "value": {
      "title":"A revised ticket title",
      "status":"inProgress",
      "assignee":{"tag":"none"}
    }
  }
}
```

List successes use the same envelope with `name: "list"` and an array in
`value`. `assignee` is an explicitly tagged option: `none` has no payload;
`some` has a `value` containing a scoped ID whose type name is `User`.
Saving changes only title/status and the revision, preserving the persisted
assignee. Revisions are arbitrary-precision `Nat`s encoded as **tagged canonical
decimal strings before JSON serialization**. JSON numbers are rejected for
`revision` and `expectedRevision`; a browser must not convert those strings
through `Number`.

Typed save errors use the operation identity and `tag: "domainError"`:

| HTTP status | `value` inside the domain-error envelope |
| --- | --- |
| 404 | `{"tag":"notFound","value":null}` |
| 409 | `{"tag":"conflict","value": currentTicketSummary}` |

The conflict payload is the current persisted public record, including its
revision. It lets the parent preserve the draft and offer a deliberate retry.
The service does not overwrite the draft or perform an automatic retry.

Invalid input, HTTP 400:

```json
{
  "tag": "decode",
  "errors": [
    {"code":"title.empty","path":[{"tag":"key","value":"title"}],"params":[]}
  ]
}
```

Errors are nonempty, and their paths/parameters are encoded explicitly. Path
segments use `key`, `index`, `variant`, or `field` tags; indices use the same
exact `nat` codec. No errors are flattened into prose.

Changed operation identity or version, HTTP 409:

```json
{
  "tag": "incompatible",
  "expected": {"namespace":"leanreact.tickets","name":"save","version":"1"},
  "received": {"namespace":"leanreact.tickets","name":"save","version":"old-client"}
}
```

The identity check happens before input decoding and before any storage call.
A wrong query/command kind yields HTTP 400 with
`{"tag":"protocol","code":"operation.kind_mismatch"}`. Other protocol
responses have this same shape. Storage failures return HTTP 500 with
`code: "storage.failed"`; native SQL diagnostics are not returned to clients.

The portable helpers `encodeRequest`, `decodeRequest`, `successResponse`,
`domainResponse`, `decodeErrorResponse`, `incompatibleResponse`, and
`protocolResponse` define these formats. `decodeHttpResponse ops request status
body : Except (Contract.CallError Empty) Contract.WireResponse` is the shared
status policy. It checks response identity, validates declared domain-error
statuses, and preserves structured decode/protocol/contract failures.
An HTTP 409 conflict and an HTTP 409 incompatible contract are distinct tags.

## Persistence and concurrency

`NativeTickets.TicketRow` is a flat `deriving LeanDb.Entity` storage record:

```text
publicScope      TEXT
publicKey        TEXT
revisionText     TEXT
titleText        TEXT
statusText       TEXT
assigneeScope    nullable TEXT
assigneeKey      nullable TEXT
```

LeanDB owns the separate internal `Stored TicketRow.id : LeanDb.Id TicketRow`
backed by SQLite's integer row ID. A unique index covers `(publicScope,
publicKey)`. Public ID keys are never parsed as SQLite row IDs. The fixture
uses `public-ticket-9007199254740993` as its public key to exercise that
separation. `TicketRow.ofSummary` and `.toSummary` explicitly map the two
representations. Reconstruction validates titles, statuses, scope/key pairs,
canonical revision text, and paired nullable assignee columns.

`Store.open` uses `LeanDb.openDb`/`Entity.specs`. Inserts, reads, and updates use
`LeanDb.insert`, `fetchAll`, `get`, typed `selectP`, and compare-and-swap `update`.
Public-ID lookup pushes both scope and key through a typed predicate against the
composite unique index. The only adapter SQL sets a busy timeout and creates
that index; transaction control belongs to the public LeanDB API.

`Store.service : TicketService IO` interprets the shared ordinary dictionary.
A save reads the current row under a `BEGIN IMMEDIATE` transaction, reconstructs
its public summary, and calls the shared `applySave`. It returns `notFound` or
`conflict current` when appropriate, otherwise updates through LeanDB's CAS
verb and commits. A defensive CAS failure rereads current persisted data.
`LeanDb.transaction` rolls back on database/IO failure and on an explicit domain
abort. Seeding and fixture insertion use `LeanDb.withTransaction`. Both APIs
compose with child-row savepoints; there is no private adapter transaction wrapper.

Every connection is protected by `Std.Mutex`; a connection is never accessed
concurrently by multiple HTTP requests. SQLite work and lock waiting run in a
dedicated `IO.asTask`, outside the HTTP event-loop continuation. The immediate
transaction and 5-second busy timeout also serialize writers using separate
SQLite connections. The test exercises two independently opened stores racing
the same revision: exactly one succeeds and the loser sees the winner's revision.

## Verification and loopback fixture

The full offline check command is:

```sh
bash tests/native/check.sh
```

It builds the executables, runs SQLite-backed Lean checks, initializes another
fresh fixture, and drives the executable JSON protocol from `tests/Run.lean`. It also
restarts the protocol process to verify persisted state survives restart.
Temporary databases and the exported manifest are retained at the printed path.
The native checks pass real dispatcher replies through LeanHttp's
`Response.decodeAs` and `decodeOutcome`, exercising its success and non-2xx
`.status` body-decoding branches without opening sockets.

The socket-free fixture can be used independently:

```sh
examples/native/.lake/cached/bin/tickets_protocol /tmp/tickets-protocol.sqlite
```

Send one JSON object per stdin line:

```json
{"method":"POST","path":"/api/tickets/list","body":{"operation":{"namespace":"leanreact.tickets","name":"list","version":"1"},"kind":"query","input":null}}
```

Each stdout line is `{"status":200,"body":actualHttpBody}`. This uses the same
`NativeTickets.dispatch` as the real server, with real SQLite underneath.
The wrapper's small HTTP `status` field is an ordinary number; domain integers
inside `body` remain tagged strings.

The parent-run real loopback test is:

```sh
bash tests/native/run-http.sh --no-build
```

It initializes a fresh SQLite fixture, launches the actual `Std.Http` server
on an OS-assigned localhost port, and runs `tickets_http_checks`. That executable
uses the actual LeanHttp libcurl adapter against the local server. The same
list/save/stale/invalid/large-revision/changed-contract scenario runs through
`clientTransport`. A separate assertion observes `LeanHttp.Outcome.status` at
HTTP 409, explicitly parses that error body with `LeanHttp.FromBody`, and checks
the typed conflict payload. It does not rely on `requestAs` decoding non-2xx
responses. The script stops only its own server process and retains logs/data.

Verified in this worker:

- `bash examples/native/build-cached.sh`: all four executables linked using
  the cached real sibling libraries on Lean 4.33.0.
- `bash tests/native/check.sh --no-build`: passed the native SQLite scenarios,
  concurrent-writer checks, executable wire protocol, and process-restart test.
- The fixtures cover `2^128 + 9007199254740993`, increment it exactly, reject
  numeric JSON revisions, preserve optional assignee IDs, and verify that failed
  calls do not change the persisted ticket.
- The linker emits a nonfatal warning for a nonexistent `/usr/local/lib` search
  directory inherited from the toolchain; all executable links succeed.

The integrating agent subsequently ran `bash tests/native/run-http.sh --no-build`:
actual LeanHttp requests and non-2xx domain decoding passed. The native browser
suite also passed against a temporary SQLite database: persistence after reload,
concurrent-save conflicts, draft preservation, and incompatible contracts.

## Limits and supported upstream proposals

This is a local native example, with no production authentication or TLS termination.
Its explicitly named fixture policy is not deployable authorization. Graceful service drain,
idempotency and migration workflows are not implemented. It binds loopback only. The HTTP server limits
request bodies to 1 MiB and connections to 64. Query/command identity is checked
but does not statically restrict the capabilities of the host `IO` monad.
Contract versions are explicit public versions, independent of LeanDB's
storage fingerprint. Automatic compatibility digests/negotiation are not
implemented. The underlying Lean JSON parser retains the P02 duplicate-textual-
object-key limitation.

Concrete extraction proposals supported by this implementation:

1. **Public transaction combinator in LeanDB.** Implemented in FS03 and used
   here. Outer writes use `BEGIN IMMEDIATE`; nested work uses savepoints and
   typed domain aborts roll back. Native connections enforce synchronous
   ownership and reject reuse after failed cleanup.
2. **Explicit lossless wire adapter.** LeanDB's storage integer codec is Int64
   and its existing JSON representation is not the browser protocol. Revisions
   are stored as validated decimal TEXT and use ontology codecs at public
   ingress/egress. An optional codec bridge should preserve that separation,
   without replacing LeanDB's current JSON instances globally.
3. **Typed endpoint status policy in LeanHttp adapters.** `requestAs` correctly
   exposes non-2xx as `.status`; an endpoint adapter must decode declared error
   bodies there. `decodeOutcome` and portable `decodeHttpResponse` demonstrate
   the seam without adding a competing blanket `FromBody` instance or changing
   LeanHttp's core semantics.
4. **Typed public-key lookup.** Implemented with a `Pred [TicketRow]` and
   `selectP`, using the existing composite scope/key index.

Generic registration lives in `engine/LeanApp`, shared HTTP codecs and browser
transport in `engine/LeanContract`, and native serving/client bindings in
`adapters/native`. `NativeTickets.Registration` contains the application-specific
publication and fixture policy.

`LeanAppNative.Managed` separately connects application dispatch to an owned
LeanDB runtime. It rebuilds handlers from the current connection inside admission,
checks their public manifest against frozen metadata, and keeps readiness outside
the database queue. The native framework check includes 44 assertions for this
adapter. Tickets' Store-based listener has not yet moved onto that lifecycle;
see [architecture](ARCHITECTURE.md#what-is-qualified) for the qualification boundary.
