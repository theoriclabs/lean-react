# LeanApp implementation status

The framework now has a portable application registry, an executable ordering domain, checked storage representations, and reusable native/browser HTTP transports. Tickets runs through those bindings against SQLite. A separate managed dispatcher connects approved application operations to LeanDB's instance lifecycle. This is a tested local foundation, not the full deployment-qualified release described in the [plan](../FULLSTACK_IMPLEMENTATION_PLAN.md).

Verification: September 7–8, 2026, on macOS arm64 with Lean 4.33.0 and Node 24.11.1, followed by the café's Linux amd64 Railway deployment. The user approved MIT licensing and hosting in Harsh Gupta's Projects. No commits, pushes, tags or package publications were made. LeanHttp source is unchanged. Unrelated LeanDB compute edits were preserved.

## Café and release-preparation checkpoint

Proof & Pour now uses the shared Lean model for browser/native prices and configuration checks, with authenticated private recipes in SQLite and a responsive React presentation. All 180 configurations agree across native/JavaScript execution; API checks cover tenant isolation, authoritative prices, the 40-recipe limit and restart persistence. Desktop/mobile browser workflows pass. The framework/native/auth profiles passed again, along with 24 auth/café client tests and the new proxy rejection/shutdown regressions.

The README explains Lean's advantages through concrete model examples. [Hosting](HOSTING.md) documents the self-contained source snapshot and container; [release evidence](RELEASE.md) records the candidate gates and hashes. These additions do not complete FS06–FS14 or qualify a paid ordering application.

[Proof & Pour is hosted on Railway](https://proof-and-pour-production.up.railway.app) in the approved workspace, with one replica, HTTPS and a persistent `/data` volume. Public browser/API checks passed signup, Secure/HttpOnly/Strict cookies, CSRF/origin rejection, authoritative prices, account isolation, save/reload/login/delete and mobile controls. Original sessions and recipes survived a real provider restart. The UI now disables unavailable options using the shared Lean preview, with accessible explanations. MIT and native dependency license notices are retained in the runtime image. Issue `leandb-lnu` tracks this hosted-app/release-preparation scope; [release evidence](RELEASE.md) records exact IDs and source hashes. Source snapshots and worker receipts are retained.

## Implemented scope

The repository now presents the framework as LeanApp, with a [documentation index](README.md), [getting-started guide](GETTING_STARTED.md), [domain guide](DOMAIN_MODELING.md) and [architecture guide](ARCHITECTURE.md). LeanReact and LeanJS stay reusable libraries inside this monorepo; LeanDB and LeanHttp stay independent. The private npm workspace is named `leanapp-workspace`; the compatible Lake package/import names and GitHub URL remain unchanged. `npm run test:docs` checks the main guides' local links and complete Lean snippets. These source changes postdate the recorded café deployment.

| Package | Current result |
| --- | --- |
| FS00 | Root `LeanApp` and `Ordering` targets, optional native Lake package, interface contract, and separate portable/native/browser check commands. Local builds pass; cold-cache Linux and immutable external distribution remain FS11 work. |
| FS01 | Currency-indexed money, all 180 configurations, checked admissibility/capacity, exact pricing, revision-bound expiring quotes, indexed order states, and deterministic quote/place/cancel/payment decisions. Native/JS parity and constructor/type rejection checks pass. |
| FS02 | Typed bindings with required policies, explicit approved exports, read/command interfaces, validated application assembly, and public manifests. Duplicate identities, ambiguous paths and conflicting storage claims are rejected. |
| FS03 | Public LeanDB transactions, nested savepoints, explicit commit/abort, synchronous connection ownership, SQL-failure guards and logical connection retirement. Integrated into the sibling checkout and Tickets. Focused native SQLite checks and the full unchanged LeanDB engine regression suite pass. |
| FS04 | Shared HTTP envelope/status codecs, generic native server/client, generic browser fetch client, and thin Tickets registration. SQLite, real loopback HTTP, and browser integration pass. Authentication is explicitly a local fixture policy. |
| FS05 | Username/password signup, OpenSSL scrypt, SQLite-backed opaque sessions, current membership checks, CSRF/cookie/origin boundaries, and a React login UI pass native, real-HTTP, and browser checks. The user selected this adapter instead of an external identity provider. The café passed public Railway checks; generic authenticated-client and ordering integration remain open. |
| FS08 | Typed runtime admission callbacks and LeanApp managed dispatch are integrated. Native callback/runtime suites, the existing hosting process/HTTP checks, and 44 managed application assertions pass. Delivery-worker and complete application-host qualification remain open. |

FS06–FS07 and FS09–FS14 remain open, along with the remaining FS05/FS08 qualification work. There is no durable command receipt/outbox, persisted ordering application, complete ordering UI, `leanapp` CLI, broadly qualified Linux release distribution, or Heroku deployment yet. The hosted café qualifies one concrete Linux/Railway target. Existing proof/validation checks make no claim about the missing layers. The [auth guide](AUTH.md) documents the implemented login flow and its limits; Tickets still uses its separate local fixture policy.

## Authorization demonstration checkpoint

The [Private Notes implementation](PRIVATE_NOTES.md) now includes a separate policy, checked grants, certified scoped reads, model response proofs and a React/SQLite application. Nine exported theorem dependencies pass an axiom audit. Eight unsafe candidate patches are rejected by the type/proof checker, admitted-proof audit or demonstrated policy-digest check; the control compiles and returns real notes. Native tests cover two real accounts sharing a tenant, retired leases, rollback and committed revocation. Real HTTP and desktop/mobile browser checks pass, including owner/tenant isolation, search/count/export, session rotation and local restart persistence.

The additive native auth host resolves authority and dispatches in one `BEGIN IMMEDIATE` transaction. The read family carries a checked grant to the database entry point and checks decoded ownership; generic `Binding.policy` is unchanged. Native scopes use a runtime lease, not a proved generative brand. SQL/FFI/authentication fidelity remains trusted. A general protected-query DSL, formal native refinement, the proposed WAL snapshot/revocation race and a protected external agent verification service remain unfinished. The [original demonstration](AUTHORIZATION_DEMO.md) and [design](AUTHORIZATION_DESIGN.md) record that broader destination.

[Private Notes is hosted separately on Railway](https://private-notes-production.up.railway.app), with a new persistent volume. Its Linux image passed model/rejection, crypto and native isolation checks; public browser/API checks passed and original sessions/notes survived a provider restart. The [notes deployment record](../deploy/notes/README.md) contains the exact deployment, source/image hashes and results. The café's original successful deployment is unchanged.

## Authentication checkpoint

The optional native auth adapter owns credential verification and session storage. Signup assigns an actor and private tenant; login replaces previous sessions. Current expiry, generation, enabled state, and membership are resolved under the runtime's owned connection callback before application dispatch. OpenSSL supplies scrypt and randomness; passwords and bearer tokens never enter browser storage. The React demo covers signup, login, session restoration, protected identity lookup, and logout.

`npm run test:auth` passed the native crypto/auth checks, including a 60-request KDF-contention regression, real HTTP persistence/restart and account-isolation checks, and 11 browser-client unit tests. `npm run test:auth:browser` passed both real-backend Playwright tests using installed Chrome. The parent also reran `test:framework` (now 33 integration tests) and `test:framework:native`; both passed. Test listeners were stopped and fixture databases retained.

Terminal sub-agents implemented the crypto FFI and browser client/UI, and performed a separate read-only security review. The review found one availability issue: rejected concurrent KDF work could consume the global login quota. The parent moved capacity admission before quota accounting and passed the new contention regression. No credential or CSRF bypass was identified by that static review; this is not a complete security audit.

Receipts are retained under `.terminal-subagents/`: `leanapp-domain-20260908T010019Z/receipt-4.json` (crypto), its `receipt-5.json` (browser), and `leanapp-transactions-20260908T010515Z/receipt-4.json` (review). All three completed successfully. The parent reviewed their changes and independently ran the checks.

Password recovery/change, MFA, email verification, breached-password screening, and public-ingress abuse controls are absent. Limits are process-local. The café qualifies a Linux/OpenSSL build and Railway ingress; broad distribution and complete host shutdown still require qualification. The browser demo's Contract call helper does not yet replace the generic client's full typed domain-error transport.

Beads issue `leandb-65i` is closed for this verified local auth implementation. `leandb-m7s` tracks public-host qualification and generic authenticated-client integration; `leandb-bk5` continues to track complete application-host shutdown and delivery-worker lifecycle.

## Check commands and evidence

Run from this repository unless a command names another directory:

```sh
npm run test:framework
npm run test:framework:native
bash tests/native/check.sh
bash tests/native/run-http.sh --no-build
npm run test:framework:browser
```

The native package normally fetches SQLite at its pinned revision. This offline verification supplied an explicit source override:

```sh
LEANAPP_LEANSQLITE_SOURCE=/Users/harshwork/code/leandb_v2/.lake/packages/leansqlite \
  npm run test:framework:native
```

An installed browser was used because the Playwright-managed Chromium executable is absent:

```sh
PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  npm run test:framework:browser
```

The two underlying browser commands were run separately and passed: six frontend tests and two native-backed tests. The portable command passed the existing compiler/ontology/runtime checks, 31 JavaScript runtime tests, 22 integration tests, TypeScript checking, 28 application assertions with eight compile-time rejections, and 35 ordering parity vectors with nine compile-time rejections. The native adapter passed checked-number/identity reconstruction and 52 generic HTTP assertions. After runtime integration, `test:framework:native` passed again and now also builds and executes the 44 managed-dispatch assertions through ordinary Lake dependencies.

`LeanAppNative.Managed` freezes approved metadata and configuration, then constructs application handlers from the current session connection inside each admitted callback. It does not retain template handlers. Tests cover policies, explicit transaction commit/domain abort, connection replacement, manifest drift, overload, drain, closure, schema gates and inspection-only sessions. Readiness and the frozen manifest remain responsive while data work is busy. Admission failures return sanitized 503 responses; host failures return sanitized 500 responses. No raw CRUD/admin route is added.

This adapter is synchronous dispatch, not a complete signal-aware application listener. Its factory and handlers are trusted native code; transactions remain explicit handler responsibility. Connection replacement is modeled under the owner lock. Actual migration/restore and signal behavior were checked separately through the existing LeanDB host. Tickets still uses its local Store integration rather than this managed lifecycle.

The transaction worker built and ran real SQLite tests; the parent independently reran its native executable and reviewed the source. A separate read-only reviewer found no concrete managed-path bug. Tests cover child-row composition, domain abort after writes, nested recovery, host/database/commit failures, automatic SQLite rollback, poisoned reuse refusal, thread ownership and a two-connection revision race. Broader fault injection and immediate physical handle disposal remain follow-up work.

The earlier interpreter-only run of LeanDB's full `Tests.lean` could not resolve its SQLite native implementation; loading a cached FFI library then exited with a segmentation fault. After disk space was restored, the worker rebuilt affected dependencies and linked native executables with SQLite. The full unchanged engine suite and native runtime suite passed. The parent independently reran both binaries in fresh directories and matched the integrated runtime/test source hashes to the build receipt. The original LeanDB library also rebuilt successfully.

The parent passed the existing hosting process/HTTP suite against the rebuilt runtime twice, including through the new explicit binary override. These checks cover listener credential separation, instance ownership, active/queued drain, SIGTERM, shutdown deadline expiry, restart, migration-plan digests, restore refusal, log redaction and partial-startup cleanup. They qualify the existing LeanDB host after the runtime refactor; they do not qualify a complete LeanApp host or delivery worker.

One real-HTTP run was killed before readiness with no diagnostic. A direct startup probe and subsequent HTTP runs passed. All temporary listeners were stopped; databases and diagnostic receipts were retained.

## Remaining build and release constraints

The disk blocker was resolved by the user. About 8 GiB was available during resumed native qualification and about 14 GiB after managed dispatch passed. A full worktree checkout had initially exhausted the filesystem and was rolled back; the retained LeanDB worktree is sparse. Test runners check free space before compilation and linking. No unrelated files were deleted to make room.

The user selected built-in username/password authentication with signup; an external identity provider is no longer a prerequisite. Railway hosting now targets Harsh Gupta's Projects; Heroku remains unselected and unqualified. LeanDB has no configured remote in this workspace. The café uses an allowlisted checksummed source snapshot, while FS11's general external distribution remains open. The [interface contract](FULLSTACK_INTERFACES.md) records the reviewed dependency identities and development overrides.

Upstream tracking is in Beads: `leandb-dxp` (transactions), `leandb-8o3` (runtime callback) and `leandb-9cw` (managed application dispatch) are closed after native qualification. `leandb-bk5` tracks the remaining complete application-host and delivery-worker lifecycle. The callback and regression runners are integrated into `../leandb_v2`; the sparse worktree retains the original build receipts. From either LeanDB checkout, the offline commands are:

```sh
LEANDB_CACHE_ROOT=/Users/harshwork/code/leandb_v2 \
  bash scripts/check_runtime_callbacks.sh --native
LEANDB_CACHE_ROOT=/Users/harshwork/code/leandb_v2 \
  bash scripts/check_regressions.sh
```

The existing socket/process suite accepts an explicit native binary:

```sh
LEANDB_RUNTIME_TEST_BINARY=/Users/harshwork/code/leanreact/.terminal-subagents/worktrees/leandb-fs03/.lake/runtime-callbacks/leandb_runtime_tests \
  python3 /Users/harshwork/code/leandb_v2/scripts/hosting_runtime_check.py
```

The terminal-subagents workflow kept separate ownership and durable receipts. Successful receipts include `leanapp-domain-20260908T010019Z/receipt-2.json` (domain), its `receipt-3.json` (independent transaction review), `leanapp-assembly-20260908T010022Z/receipt-3.json` (HTTP), and `leanapp-transactions-20260908T010515Z/receipt-3.json` (resumed native qualification), all under `.terminal-subagents/`. The full engine receipt is in `worktrees/leandb-fs03/.lake/regressions/run.rc7oj8wz/receipt.json`; the runtime receipt is in `worktrees/leandb-fs03/.lake/runtime-callbacks/native-qualification.json`.

The assembly worker's fourth run authored the managed adapter and tests but stalled on connection timeouts after correcting an initial test syntax error. The parent stopped that worker; `receipt-4.json` records exit 143, not success. The parent completed the connection-lifetime review, removed retained template handlers, integrated the normal Lake check, and passed the native profile. The optional offline checkpoint runner also passed all 44 assertions and confirmed its imported artifacts were unchanged; its receipt is `adapters/native/.lake/managed-checks/run.usmtvfkj/receipt.json`. The stopped worker and its child exited. Initial failures and earlier receipts are retained.
