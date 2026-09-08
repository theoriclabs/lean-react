# FS02 portable assembly

Run `bash tests/app/check.sh` from the repository. It builds only `LeanApp`, runs
the in-memory policy/dispatch fixture, and verifies expected compiler diagnostics.
Logs go to a unique `.lake/app-check.*` directory. No network or native database
is required.

## Parent integration API

- `Binding m Read Write operation` retains the existing indexed `Operation`.
  Required fields are `policy`, `handler`, and `http`; `metadata` defaults empty.
  `handler` receives `RequestContext`, the capability selected by operation kind,
  and the typed input, returning the existing `m (DomainResult Output Error)`.
- `Policy m Read operation` receives context, read capability and typed input;
  it returns `m (CallResult Unit Empty)`. There is deliberately no allow-all default.
- `ReadCapability m Read.read` interprets a selected `Read α` into `m α`.
  `CommandCapability m Read Write` adds `write : Write α → m α` and `toRead`.
  `Binding.executionKind` is the contract kind, so query and command cannot drift.
- `Binding.toRoute binding context capability` calls `Route.ofHandler` after
  wrapping policy and handler, producing `Route (Authorized m)` where
  `Authorized m = ExceptT (CallError Empty) m`. Authority errors use the outer
  channel; domain errors retain their original codec inside the route.
- `Binding.approve binding provide` explicitly produces an `Export m`; `provide`
  selects capabilities from the trusted context. `Module m` contains a name,
  dependencies, metadata, approved exports, and storage ownership claims.
- `Application.create name modules metadata` returns `Ontology.Validation`.
  It rejects duplicate module names, missing dependencies, duplicate full
  operation IDs (including version), duplicate HTTP bindings, invalid literal
  paths, empty storage identities, and incompatible claims on one physical table.
  Different explicit operation versions can coexist at different paths.
- `Application.manifest` contains only approved operation descriptions, their
  existing codec schemas, HTTP bindings and public metadata. Storage claims and
  private service declarations do not enter this manifest.
- `Application.transport app context` returns the existing `Contract.Transport m`;
  `.interpreter` is the existing typed client. `Application.dispatchHttp app
  context http request` also requires the HTTP endpoint's operation ID to match
  the wire request. `HttpBinding` has `path : String` and `method : HttpMethod`
  (currently `.post`, the default). Construct it as `{ path := "/value" }`.

## Trust and limits

`RequestContext.anonymous requestId` cannot set a principal. The private context
constructor has no JSON or wire decoder. `TrustedNative.issueContext principal
requestId` is an explicitly trusted issuance function: the host must authenticate
the principal first. Claims currently contain actor, tenant and session generation;
they do not implement expiry, membership verification, sessions or CSRF.

This is API separation, not an arbitrary-Lean sandbox. Host authors choose the
read operation family and interpreter, which must actually be read-only. A handler
written concretely in `IO` can use IO, and arbitrary trusted Lean code can import
the issuance escape hatch or capture a write capability. Ordinary generic handlers
need only a `Monad m` and the selected interface; no raw connection or IO lifting
operation is provided by `ReadCapability`.

Command capability is an interface, not a transaction executor. This fixture uses
`StateM` and a deliberately supplied local policy only. Native transactions and
authentication are separate implemented adapters; idempotency and durable effects
remain unfinished. See [framework status](../../docs/LEANAPP_STATUS.md) for current
coverage. No skeleton Command/Policy/Effect modules were added.

HTTP paths are exact ASCII literals; parameter patterns, percent escapes, query
strings, dot segments, duplicate separators and trailing separators are rejected.
Adapters must not normalize these into additional aliases. HTTP codecs, envelopes
and status rules remain Contract/native-adapter concerns. Storage adapters must
canonicalize physical table identifiers (database/schema included); equal mapping
IDs are an explicit assertion of a shared complete mapping, not schema equivalence
inferred by this library. Dependencies require presence, permit cycles and impose
no initialization order. Dispatch constructs a checked Router per context/request;
this modest implementation does not cache prepared native registries.
