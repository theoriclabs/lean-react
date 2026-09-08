# LeanApp implementation plan

Build a reusable application layer around the working LeanReact, LeanDB, and LeanHttp libraries. The first integration carries the existing Tickets application onto that layer. A configurable ordering application then tests the main premise: domain types and executable rules can drive several interfaces while storage and HTTP remain replaceable execution adapters.

Status: execution in progress. The local FS00–FS04 foundation is implemented, including the full native LeanDB regression run. FS08 runtime callbacks and managed application dispatch are integrated with native qualification; complete application-host and delivery-worker lifecycle work remains open. The café now qualifies a concrete Linux/Railway target with username/password auth. The full release remains incomplete; see [implementation status and evidence](docs/LEANAPP_STATUS.md) for exact passed and pending gates. This plan implements [FULLSTACK_VISION.md](FULLSTACK_VISION.md). The earlier [P00–P09 implementation plan](IMPLEMENTATION_PLAN.md) records the LeanReact experiments that preceded this framework work.

The approved repository direction is the LeanApp monorepo: LeanReact and LeanJS are reusable libraries within this checkout; LeanDB and LeanHttp remain independent. Product naming and developer navigation now follow that decision while compatible Lake/import/wire names and the existing GitHub URL remain unchanged. See [architecture](docs/ARCHITECTURE.md#names-and-compatibility).

## First release and its limits

The first LeanApp release delivers a Lake-based application framework, an optional native adapter package, and a project generator. It includes typed public operations, transactional commands, authenticated access, durable effect delivery, migrations, and a LeanReact application using shared domain functions. It ships reproducible Linux builds and two qualified deployment profiles:

- A native application with SQLite on a Railway persistent volume.
- A stateless Heroku web gateway using the same operations against a separately hosted durable Lean application service.

The release must demonstrate a browser and an independent CLI consumer using the ordering domain without copying its pricing or command rules. A second browser presentation must reuse the domain and at least one behavior hook with different markup.

Initial constraints are one authoritative SQLite owner per instance, client-rendered React, explicit wire codecs, and named queries. SSR, Server Components, general offline synchronization, PostgreSQL, a hosted control plane, automatic TypeScript bindings, and universal query compilation remain later work. Payments use a controllable provider fixture for workflow qualification; integrating a commercial payment provider is a separate application concern.

## Implementation choices

Keep `LeanOntology`, `LeanContract`, `LeanJS`, and `LeanReact` in this repository initially. Add portable `LeanApp` modules under `engine/` and place SQLite/server bindings in an optional `adapters/native/` Lake package. The neutral root build must continue to work without SQLite or libcurl. The vision's package names are logical boundaries; separate publication can follow demonstrated reuse.

Keep domain code as ordinary Lean declarations. Start the ordering model early and use its functions to settle the framework's interfaces. Use explicit descriptors and storage mappings first. Derivation can remove repeated structural code after both applications identify the repetition.

Retain Lean 4.33.0 for this release. Extend the existing LeanJS compiler only for a concrete domain expression required by the sample, with native/JavaScript parity evidence. An unsupported browser definition receives a dependency diagnostic; relocating it to the server is an explicit application decision.

Reuse `Contract.Operation`, `Route.ofHandler`, and `Transport.interpreter`. Application policy and transaction wrappers sit around typed handlers before registry erasure. Keep legacy CLI/argv registration available through adapters. Application routing must not inherit LeanDB's entire CRUD/admin surface.

Use explicit commit/abort results for domain commands. Database failure, host failure, and a rejected command all have defined rollback behavior. Store idempotency results and outbox intents in the same authoritative transaction as accepted changes. Keep network execution outside that transaction.

Keep the existing nominal public identities and exact-integer wire format. The new storage mappings must use checked finite representations or exact text for values that exceed SQLite's integer range. Preserve legacy LeanDB codecs during initial integration; a general codec redesign is not a prerequisite.

Treat the existing sibling worktrees as shared work. Future LeanDB implementation changes should use an isolated branch/worktree based on an identified revision and its task-tracking workflow. Do not absorb the unrelated compute experiments into this plan. LeanHttp is initially a pinned dependency; add upstream changes only when a failing integration fixture demonstrates the need.

## Repository boundaries and intended files

Paths described as new below are implementation targets, not files created by this planning pass.

| Repository | Intended changes | Existing starting point |
| --- | --- | --- |
| `leanreact` | New `engine/LeanApp/` portable definitions, `engine/LeanAppWeb/` frontend helpers, `adapters/native/` native package, and `examples/ordering/` application package. Add focused application tests and release tooling. | [Operation types](engine/LeanContract/Operation.lean), [typed routing](engine/LeanContract/Transport.lean), [native Tickets adapter](examples/native/NativeTickets/Storage.lean), and [build script](scripts/build.mjs). |
| `leandb_v2` | Public transaction API, reusable instance/admission hooks, and focused tests. Add storage/reflection helpers only where the adapters require them. Preserve existing CLI and migration contracts. | [Db.lean](../leandb_v2/LeanDb/Db.lean), [Runtime.lean](../leandb_v2/LeanDb/Runtime.lean), [Cli.lean](../leandb_v2/LeanDb/Cli.lean), and [hosting contract](../leandb_v2/HOSTING.md). |
| `leanhttp` | Reuse request/session APIs and typed outcomes. Qualify application-client and worker use against local fixture servers. Any upstream patch includes its regression test and changelog entry. | [Client contract](../leanhttp/README.md) and [async implementation](../leanhttp/LeanHttp/Async.lean). |

Suggested portable modules are `LeanApp.Application`, `LeanApp.Module`, `LeanApp.Command`, `LeanApp.Policy`, and `LeanApp.Effect`. Frontend modules use `LeanAppWeb` to keep their React dependency visible. Native implementations initially use a `LeanAppNative` library with `Storage`, `Server`, `Client`, and `Runtime` modules. This avoids competing library roots while preserving the vision's separation of responsibilities.

## Work packages and dependency order

Dependencies below are completion dependencies. A prototype may start sooner against an agreed interface, but a package cannot pass its gate until its dependencies pass. Work can proceed independently where the dependencies permit; integration uses the recorded package interfaces.

| ID | Deliverable | Depends on | Completion gate |
| --- | --- | --- | --- |
| FS00 | Baseline, package layout, and interface fixtures | None | Neutral and optional native builds have reproducible entry points and recorded dependency identities. |
| FS01 | Executable ordering domain and portability check | FS00 | Pricing, admissibility, and representative state transitions run from the same Lean source natively and in JavaScript. |
| FS02 | Application assembly and typed bindings | FS00 | Duplicate exports and incompatible handler bindings are rejected; an in-memory application dispatches approved operations. |
| FS03 | Composable SQLite transactions and checked mappings | FS00 | Nested child-table writes, explicit abort, and failure recovery preserve transaction semantics. |
| FS04 | Reusable HTTP bindings and Tickets integration | FS02, FS03 | Existing Tickets behavior passes through the generic runtime and both clients, with no hand-maintained per-operation dispatcher. |
| FS05 | Principal/session integration and operation authority | FS04 | Actual authentication and tenant/operation policies hold across reads, writes, and session changes. |
| FS06 | Authoritative commands and idempotency | FS05 | Concurrent and retried commands produce one accepted state change with a durable result. |
| FS07 | Durable effect execution | FS06 | Claimed work recovers after crashes; duplicate delivery and uncertain outcomes follow the declared policy. |
| FS08 | Instance ownership, lifecycle, and migration hooks | FS03, FS04 | Application work shares admission, drain, and ownership with private administration. |
| FS09 | Persisted ordering application and coherent queries | FS01, FS06, FS07 | Configuration, pricing, inventory, and derived query results remain consistent through commands and rule changes. |
| FS10 | Typed routes, operation resources, and complete ordering UI | FS05, FS09 | Browser workflows preserve drafts and isolate users while using the compiled domain rules. |
| FS11 | Project tooling and clean Linux artifacts | FS04 | A generated Tickets project builds and runs outside the development workspace without sibling caches. |
| FS12 | Domain evolution, recovery, and Railway qualification | FS07, FS08, FS09, FS10, FS11 | The ordering release survives redeploy, exercises migration failure and restore, and runs on Railway. |
| FS13 | Remote authority and Heroku qualification | FS12 | The Heroku gateway preserves the same command semantics against the durable service. |
| FS14 | Independent reuse and release handoff | FS12, FS13 | A separate consumer and second presentation pass the domain-evolution exercise; release evidence is complete. |

The early integration chain is FS00 → FS02/FS03 → FS04. FS01 runs alongside it and must finish before the ordering framework interfaces are treated as stable. After FS04, authority work and runtime lifecycle work can proceed independently; clean Linux packaging can also start. FS09 and FS10 then exercise those interfaces together before deployment qualification.

## FS00: establish an executable baseline

Add the portable Lake target and optional native package layout with a minimal importing fixture. Define the source roots for browser exports, native handlers, and shared domain declarations. Preserve the current engine/example separation and keep all new native dependencies out of default frontend targets.

Record the current compiler ABI, wire envelope, operation-version policy, and sibling dependency revisions in a short interface contract under `docs/`. Record which files provide the legacy Tickets protocol and which new fixture consumes it. Pin native dependencies through ordinary Lake requirements; development may use local paths, while the clean-build fixture must support immutable source references without a dependency on another checkout's `.lake` directory.

Re-establish the existing test baseline once at implementation start. Keep temporary databases and generated files isolated from user data. Add CI entry points that distinguish a portable build from native and browser qualification. Usage documentation marks commands as proposed until their implementation passes.

Gate: an empty application package imports the neutral library and builds; the optional native package builds through Lake; existing public imports and the current test suite pass. Record the source revisions with those results.

## FS01: test the domain-modeling premise first

Create `examples/ordering/Ordering/Domain/` as an ordinary Lean library. Use the Eats configuration/pricing examples as source references, but separate the portable model from their existing LeanDB imports. Reuse shared definitions where practical and record any deliberate adaptation. Do not copy their manually maintained summary fields as authoritative data.

Model currency-indexed money, a finite product configuration space, checked admissibility, and an executable pricing rule. Include a capacity invariant and an order lifecycle whose alternatives carry the data each state requires. Define explicit `Quote`, `PlaceOrder`, and `CancelOrder` inputs and errors. A quote identifies the offer/rule revision and expiry; accepting a changed or expired quote produces a typed domain error that prompts a new quote.

Keep pricing preview pure. Store a pricing-rule data structure when the rule is configurable, and evaluate it through one Lean function. Use proof-bearing values where the invariant is useful, with checked reconstruction from raw data. Supply an in-memory interpretation and deterministic time/identifier fixtures for native tests.

Compile representative calculations and transitions through LeanJS immediately. Compare outputs on valid configurations, rejected combinations, Unicode labels, and large exact amounts. Add compile-time failures for mixing currencies and composing incompatible workflow states. Test that private constructors or proof fields actually enforce the claimed invariants.

Gate: the same domain functions produce matching native/JavaScript results with no database or React import. Any compiler extension has a focused parity test and a documented supported boundary. A modeling or portability failure is resolved here before the complete ordering app is built.

## FS02: assemble applications from typed definitions

Implement `Application` and `Module` values with explicit exported operations, dependencies, and public metadata. Bind each existing `Operation kind Input Output Error` to a handler with the matching types, policy slot, and execution kind. Keep ordinary service records directly callable without registration.

Use `Route.ofHandler` as the checked erasure boundary. Compose registries with duplicate operation/version detection and route-conflict detection. Add a storage ownership manifest that rejects two incompatible mappings for the same physical table. Sharing a table requires an explicit common mapping identity.

Define the request context and abstract read/command capability interfaces now; concrete authentication and transaction interpreters follow. Test dispatch with an in-memory interpreter whose policy is explicitly supplied. Public manifests describe only registered public projections and operation codecs. Reflection does not grant field mutation, persistence, or publication.

Gate: negative Lean cases reject wrong handler inputs/results and use of a write capability through a read-only interface. Runtime composition rejects duplicate identities, ambiguous paths, and table collisions before listening. A context value cannot be manufactured from an arbitrary client-supplied principal field.

## FS03: make transaction semantics composable

Add a public API in LeanDB, preferably in a dedicated `LeanDb.Transaction` module with integration in `Db.lean`. Establish one connection-scoped transaction owner and nesting state. Preserve the current convenience behavior of multi-row insert/update operations by routing their internal transactions through this API.

Use `BEGIN IMMEDIATE` for an outer application write transaction. Nested operations use uniquely named savepoints. A nested failure rolls back to its savepoint; the caller may explicitly handle that result, while an unhandled failure aborts the outer transaction. An inner request cannot upgrade the outer transaction's lock mode. Document direct raw transaction SQL as an escape hatch outside the tracked API.

The command-facing API returns an explicit commit or abort decision with a typed domain error channel. An abort rolls back even if it is a successful value in the surrounding `IO` or database error transformer. Commit failure attempts rollback and preserves a typed failure. If cleanup cannot establish a reusable connection state, discard that connection instead of returning it to normal service.

Add the initial checked storage mapping API to the native adapter. Map public IDs to indexed internal rows and validate all reconstruction. Use bounded storage wrappers or validated exact text for amounts and revisions. A direct `Nat` mapping must not silently reach the legacy narrowing encoder. Test representable limits, `2^63`, and much larger inputs.

Gate: parent/child writes inside an outer transaction succeed; a domain abort after an earlier write leaves no change; a caught savepoint failure leaves the specified outer state; database/commit failures recover or retire the connection. Two independent test connections competing for the same revision admit one winner. These tests concern transaction behavior, separately from the runtime's exclusive-instance policy.

## FS04: move Tickets onto reusable bindings

Extract route/status policy from `Examples.Tickets.Contracts` and the native example into reusable operation HTTP bindings. Keep its existing routes, error envelopes, and explicit version behavior compatible. Generate or derive request dispatch from the approved registry and bind codecs once. Retain fixtures of the legacy wire format while removing duplicated application dispatch code.

Implement the native LeanHttp client and browser-fetch client for the shared transport envelope. Decode non-success domain responses, preserve exact integers and scoped IDs, and keep transport errors separate from contract mismatches. Reuse explicit codec composition; a browser codec generator is only needed if the extracted representation cannot already be interpreted by the adapter. Any trusted JavaScript conversion code gets protocol conformance fixtures.

Move the native Tickets store to the public transaction API and use a typed indexed lookup for public identity. Move serving to the optional native package, with bounded requests and a socket-free dispatcher for tests. At this stage authentication is a named local fixture policy; the runtime must not label it a deployable authentication adapter.

Gate: the existing list/save/conflict flows work through generic registration, in-process dispatch, a real HTTP connection, and the compiled browser UI. An unknown or incompatible operation cannot invoke a handler. The board and inbox continue to share the same component behavior.

## FS05: bind identity and authority

Implement verified principal and session records with actor, tenant membership, expiry, and a session generation. Use opaque browser sessions stored on the authoritative server, with secure randomness and cookie handling supplied by qualified host dependencies. Per the user's implementation decision, provide simple username/password authentication with signup instead of requiring an external identity provider. Use a maintained password-hashing and random-number library; do not implement cryptographic primitives in application code. The local adapter uses OpenSSL scrypt and SQLite-backed sessions; see [authentication](docs/AUTH.md) for implementation and qualification limits.

Keep expensive password verification outside the command transaction, then resolve local membership and operation policy against current authoritative data. Read handlers receive scoped read capabilities. Command handlers receive the selected transaction capability, with raw `Conn` and unrestricted `IO` confined to native adapters. Provide explicitly named escape hatches for trusted native extensions; this is an API boundary, not a sandbox for arbitrary code.

Wire session lifecycle, logout, CSRF protection, and the trusted-proxy policy into the HTTP adapter. Public projections apply field and row policy. An inaccessible identity must not disclose its record through a conflict response. Replacing or revoking a session invalidates client ownership and prevents later responses from updating another session's UI.

Gate: valid login/logout works with the chosen adapter; wrong tenant, expired/revoked session, missing CSRF data, forged identity, and forbidden reads are rejected. A policy change ordered before command authorization is observed; a change ordered afterward is defined by the transaction's serialization order. Negative API tests establish that ordinary query code cannot obtain a write capability.

## FS06: commit commands once per request identity

Implement a command executor that authenticates and decodes, enters the transaction, checks current policy, resolves idempotency, checks expected revisions, runs the pure decision, and persists its accepted result. Pass clock facts and generated identities explicitly to the decision where they affect meaning.

Store command receipts keyed by tenant, actor, operation version, and caller-supplied idempotency key. Define a versioned canonical encoding for the request digest; object order and normalization must not accidentally change identity. Reusing a key with a different request yields a typed conflict. Only committed successes are cached initially. A domain rejection rolls back and can be evaluated again on a later attempt; document this policy.

Check current access before replaying a stored success. Persist the exact result version required by the contract, the state change, and any outbox intents atomically. Use database uniqueness to enforce receipt identity even under concurrent admission. Specify retention and the point after which a previously used key may no longer deduplicate; clients must not retry ambiguous work beyond that policy as if it were still protected.

Gate: duplicate requests, response loss after commit, concurrent retries, a reused key with a changed body, and stale expected revisions produce the defined outcome. A crash before commit leaves no receipt or mutation; a crash after commit allows the same success to be recovered without a second change. Authorization failure cannot retrieve a private stored result.

## FS07: execute durable effects

Implement outbox records with a typed payload/version, command identity, stable delivery key, attempt count, availability time, and lease generation. A worker claims a bounded batch in a short transaction, performs HTTP outside it, and acknowledges through another transaction conditional on its lease generation. An expired worker must not overwrite a later owner's result.

Model delivery success, retryable failure, permanent rejection, and uncertain outcome. Support bounded retries, explicit deadlines including queue time, lease recovery, and inspection/reconciliation commands. LeanHttp's lack of transfer cancellation must not turn an abandoned request into a claim that the provider did no work.

Qualify against a local provider fixture that records external idempotency keys and can delay or drop responses. A callback route verifies the provider's authentication through its adapter, deduplicates the callback, and applies a normal domain transition. Keep the delivery guarantee explicit: retries can duplicate a transfer; an external idempotency contract or reconciliation handles that boundary.

Gate: crash before delivery, response loss after provider acceptance, crash before acknowledgement, expired lease, stale acknowledgement, and duplicate callbacks are exercised. Domain state and the creation of its first intent are atomic. Worker concurrency and queue depth remain bounded under a failing provider.

## FS08: share instance lifecycle with application work

Refactor the existing LeanDB runtime narrowly to admit a typed callback under its instance/session ownership and database lock. Separate admission/queue/drain logic from argv dispatch while preserving the existing CLI and managed HTTP behavior. The adapter borrows the owned connection within the callback; it must not open a second unmanaged connection for public operations.

All application data work, including outbox claim/acknowledgement, participates in the same lifecycle. Network delivery runs outside the database lock but remains accounted for in worker shutdown. Drain stops new public work and new worker claims, completes admitted transactions, and handles in-flight delivery within the shutdown budget. Leases recover unfinished delivery after restart.

Expose public application routes and private runtime administration with distinct credentials and listener configuration. Reuse migration-plan digests, read-only planning, checksum-bound restore, readiness gates, and instance locks. Health/status must stay responsive while data work is busy. Log operation identity, request/command ID, duration, and typed outcome without private inputs or credentials.

Gate: public application operations cannot bypass drain or the admin boundary. A second managed runtime cannot acquire the same instance. Startup failure closes partially opened resources. `SIGTERM`, deadline expiry, migration failure, restore refusal, and crash/restart preserve the existing runtime contract through the new callback path. Re-run LeanDB's managed-runtime tests for this change.

## FS09: build the persisted ordering application

Bind FS01's model to storage and the command executor. Persist offer/rule revisions, exact accepted quote snapshots, order state, and inventory reservations. `PlaceOrder` checks current offer admissibility and the quote policy, reserves inventory, creates the order, and records its next effect in one transaction. `CancelOrder` releases inventory at most once and records the appropriate workflow transition.

Introduce search summaries and tabulated configuration prices as explicitly derived representations. For this finite sample, recompute them synchronously with a rule update so authoritative queries see a coherent state. Store the source rule revision and check it during reconstruction. A later asynchronous projection must expose freshness; it is not needed to establish the first sample's behavior.

Add named typed search queries with bounded results and deterministic ordering. Use existing LeanDB predicate/select APIs for pushable lookup and filtering. Reuse pure pricing/admissibility helpers for residual checks; do not promise to serialize `Ontology.Query` function closures. Compare optimized and reference execution over the same snapshot, including filter/limit ordering and rejected configurations. Add only the neutral-reflection bridge required by these mappings.

Gate: two clients competing for the last unit cannot both reserve it; repeated cancellation cannot release it twice. A pricing change updates the preview inputs and query projections while preserving historical accepted prices. Stale/expired quotes fail with useful typed errors. Directly corrupted representations fail reconstruction. Query budgets return a declared incomplete/limit result when applicable.

## FS10: complete the browser application

Add a typed route layer for product selection, quote review, order detail, and operator views. Route parsing produces validated domain inputs. Build a reusable operation resource/cache keyed by service identity, session generation, tenant, operation version, and canonical input. Begin with explicit command invalidation declarations.

Build the configuration editor around the shared parser and pricing function. Preserve raw invalid drafts. Submit command inputs with a stable idempotency key that survives ambiguous retries, and issue a new key when the user starts a different command. Represent expired quotes, inventory conflicts, provider uncertainty, and contract incompatibility as separate renderable outcomes.

Use existing LeanReact hooks, typed field bindings, and ordinary CSS. Provide replaceable editor and summary components. Retain service-keyed mount behavior and suppress replies to retired sessions or service instances. Route changes and reloads recover orders through public identities and current server state.

Gate: browser tests cover configuration preview, invalid input, successful order, competing reservation, cancellation, lost response/retry, logout during a request, and an incompatible old client. Check keyboard navigation, focus, and error announcements. Reuse one behavior hook in an operator layout before declaring the UI integration complete.

## FS11: make clean builds and project creation work

Implement the proposed `leanapp new`, `dev`, `check`, `build`, and `doctor` commands around Lake and the existing bundler. Keep the initial executable in the optional tooling/native package if necessary; ordinary browser consumers must not acquire its native dependencies. The generator writes editable Lean declarations and explicit adapters with pinned dependencies.

Use Tickets as the first generated-project fixture. Build it in a fresh directory, then in Linux with empty build caches. Remove reliance on the cached native build script and direct paths into sibling dependency artifacts from the supported release path. Preserve the cached script as a documented local convenience while its users migrate.

Emit the native executable, selected browser modules, static assets, and manifests identifying source/dependency revisions, wire versions, storage lineage, and compiler ABI. Build a multistage Linux image and inspect its runtime dependencies. Include libcurl/certificate roots when required; static browser assets should run with the native server alone. Bind `$PORT`, set the database path explicitly, and keep immutable assets outside the volume.

`dev` preserves its database across restart and reports schema changes as migration work. `check` reports unsupported browser dependencies and invalid application assembly at the Lean declaration. `doctor` validates the selected deployment profile, writable storage where required, and public/admin separation.

Gate: a generated application builds and runs without the original workspace. A clean Linux container executes a typed operation, serves the compiled UI, and retains data in a mounted test directory across replacement. Its public manifest contains no private declarations. Record image size, startup time, and build time without inventing production capacity claims.

## FS12: qualify evolution, recovery, and Railway

Extend the clean-build pipeline to the complete ordering application. Create two concrete release fixtures: one changes only the pricing rule; another adds a required domain concept with a typed migration for historical rows. Both record distinct release and contract identities even where SQL shape alone does not reveal the semantic change.

Implement a release driver that stages the candidate executable, plans against a consistent snapshot, records the exact plan digest, drains the current owner, obtains the final backup, and verifies its copy outside the instance volume. After ownership transfer, recheck the candidate plan against the live instance, apply the selected migration, verify data, and admit traffic. If the plan has changed, stop before modifying data. A migration failure keeps the candidate unready.

The Railway profile uses one application owner with SQLite under `/data`. Local-volume migration runs after the volume is mounted, before readiness. Test the actual process identity's write permissions and configure a termination grace period that matches the drain budget. Record the brief downtime of the single-volume deployment profile. These constraints follow Railway's [volume lifecycle](https://docs.railway.com/volumes) and [volume limitations](https://docs.railway.com/volumes/reference); verify the provider settings again during qualification.

First run the release/restore scenarios locally with disposable volumes. Then qualify a named Railway environment with its configured secrets, durable volume, and off-volume backup destination. Keep account/project details and migration-selection records in deployment configuration, outside public domain code.

Gate: the full app survives process kill and redeploy on Railway. A stale migration plan and a corrupt backup are refused. A verified backup restores into a fresh instance, with restored identities and historical quote values checked. An old browser can either use its supported contract or retain its draft through a typed incompatibility response. Record what data would be lost by restoring after new writes, and demonstrate the selected forward-repair or restore policy.

## FS13: qualify remote execution and Heroku

Build a stateless native web gateway using the same approved operation registry and FS04's LeanHttp transport. It serves browser assets and forwards the complete operation to the authoritative service. The command's policy, idempotency receipt, transaction, and outbox remain at the durable service. Remote row-by-row CRUD is not the command boundary.

Use a signed, short-lived actor context with a gateway credential that authenticates the service. Validate the signature, issuer, audience, expiry, and current domain access at the durable end. Use qualified signing/verification primitives, pin the trusted gateway keys, and exercise key rotation. Strip untrusted forwarded identity headers; never allow a browser to choose the delegated actor. Retries preserve the original command key and canonical input.

Prototype the two-process topology locally as soon as FS04–FS06 are ready; finalize it against the qualified durable tier after FS12. Exercise network partitions, delayed replies, service restart, session expiry, and an invalid delegated context. Bounded admission and timeouts must work even when the upstream service is unavailable.

Deploy the web tier to a named Heroku environment, using its supplied `$PORT` and no durable local state. Heroku's [container runtime](https://devcenter.heroku.com/articles/container-registry-and-runtime) and [dyno filesystem](https://devcenter.heroku.com/articles/dynos) require a separately durable store for this SQLite profile. The Railway application from FS12 can provide the authoritative tier over authenticated HTTPS.

Gate: restarting or replacing the Heroku dyno loses no authoritative state. A reply lost across the gateway can be retried without a second order. Authentication and current policy are still checked at the durable service. Deployment documentation explicitly names the separate durable tier and does not claim an all-Heroku SQLite deployment.

## FS14: demonstrate reuse and finish the release

Create an independent Lake consumer that imports the ordering domain and public contracts through immutable dependency references. Give it a CLI client using the same operation registry. Build a second browser presentation from the shared behavior hook and different components. This work can start after FS09/FS10; final qualification includes both deployment profiles.

Change one product choice so it alters admissibility and price. Build both consumers, migrate historical data under the selected policy, and complete an order from each. Record the domain code reused, adapters written, and any business rule copied. Remove avoidable copies before treating the framework boundary as complete.

Publish an implemented-support matrix and a qualification record with exact source/dependency identities, commands, results, deployment topology, and remaining limitations. Measure compiler/runtime overhead on the actual samples. Run repository-specific release checks and prepare appropriate version/changelog updates for changed packages. Release publication follows the active repository workflow and release scope.

Gate: the generated project, independent consumer, second UI, domain-evolution fixtures, and both hosted profiles pass from pinned inputs. A README command leads to a working local application, and a deployment recipe names all backing services it requires.

## Verification and evidence

Use the existing suites as regression gates; add tests for externally visible behavior and failure boundaries introduced by each work package. A placeholder implementation or a type signature alone does not complete a package. Avoid rerunning unchanged full suites after every documentation or wiring adjustment.

| Changed area | Existing checks to retain | New evidence |
| --- | --- | --- |
| Portable model, compiler, contracts | `npm test`; focused compiler and ontology checks | Domain parity corpus, negative currency/state examples, operation/handler binding failures, private-export checks. |
| Native storage and transactions | `bash tests/native/check.sh`; LeanDB engine tests | Savepoints, domain-abort rollback, exact storage bounds, race and crash scenarios. |
| HTTP and native clients | `bash tests/native/run-http.sh --no-build` after a current native build; `lake test` in LeanHttp when it changes | Protocol compatibility, non-success error decoding, bounded failures, remote command retry. |
| Browser behavior | `npm run test:browser` and `npm run test:native:browser` | Ordering flows, session replacement, draft recovery, typed routing, keyboard/focus checks. |
| Managed runtime and migrations | LeanDB runtime tests and `scripts/hosting_runtime_check.py` | Callback admission, shared instance ownership, worker drain, migration digest binding, off-volume recovery. |
| Packaging and release | Fresh Lake/npm builds and existing repository release checks | Empty-cache Linux build, generated external consumer, actual Railway and Heroku receipts. |

Keep operational logs separate from test fixtures that intentionally contain sample data. Each completion record names changed source roots, dependency identities, commands run, and the specific outcomes asserted. For LeanDB work, attach this evidence to its Beads task; the FS identifiers in this document express design dependencies rather than replacing its issue tracker.

The tests recorded in the vision are the inherited review baseline. This plan does not mark the new FS work complete and does not treat previously passed browser or deployment checks as evidence for a later implementation revision.

## Risks to resolve at their earliest gate

| Risk | First gate | Decision rule |
| --- | --- | --- |
| Rich domain definitions exceed the browser compiler subset | FS01 | Extend one required construct with differential evidence, or explicitly keep that computation native. Do not weaken the domain model to hide a compiler limitation. |
| Transaction nesting or domain-error layering commits rejected work | FS03 | Require explicit commit/abort semantics and failing-path tests before adding order commands. |
| Policy/session support depends on missing host verification primitives | FS05 | Qualify maintained password-hashing and randomness dependencies, session handling, and public-ingress abuse controls before calling the native host deployable. |
| Runtime callbacks bypass locks or deadlock under administration | FS08 | Use one owned connection path with admission tests and bounded shutdown; preserve the legacy runtime regression suite. |
| Derived search data drifts from pricing rules | FS09 | Use synchronous recomputation for the first finite domain; introduce asynchronous freshness only with a concrete need. |
| Clean Linux builds rely on local caches or runtime libraries | FS11 | Fail the external-consumer/container gate and repair packaging before provider work. |
| Provider lifecycle cannot implement the selected migration cutover | FS12 | Adjust the deployment driver and document its downtime/recovery behavior; require a real restore exercise. |
| Gateway retries or delegated identity change command semantics | FS13 | Run the same authority/idempotency scenarios through the two-process path and retain the atomic boundary at the durable service. |

Re-estimate remaining effort after FS01, FS04, and the first clean Linux build. Those gates settle compiler scope, the public API, and native packaging risk. Calendar dates before those results would be guesses.

## First implementation slice

Start with FS00, then implement the FS02/FS03 contracts needed to carry Tickets through FS04. Run the FS01 domain prototype alongside that interface work, or immediately after FS00 when working sequentially. Keep changes in separate reviewable batches for portable assembly, the LeanDB transaction API, and the native/browser adapters.

The first integration is complete when one command registers Tickets' operations, starts the local server with a temporary database, mounts the existing compiled workspace, accepts a save, rejects a stale save, and survives restart. The application uses the reusable transaction and transport path, while the ordering prototype already demonstrates that the intended domain calculations fit the native/browser boundary.
