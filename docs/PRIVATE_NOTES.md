# Private Notes: make an authorization mistake fail a check

[Documentation](README.md) · [Original demonstration](AUTHORIZATION_DEMO.md) · [Implementation design](AUTHORIZATION_DESIGN.md)

A developer asks an agent to add an export endpoint. The agent removes an ownership check while reusing the query. In an ordinary application, that change might pass the type checker and a happy-path test. Here, the query has to satisfy a separately stated ownership policy. Removing the check breaks its proof.

Private Notes makes that failure inspectable, alongside a working username/password app backed by Lean and SQLite. React is the presentation layer; the authorization model does not import React, HTTP or a database library.

## Try the demonstration

Open [Private Notes on Railway](https://private-notes-production.up.railway.app). Public browser/API checks passed, and original sessions and notes survived an actual service restart. Use a disposable password; there is no account recovery. This is a synthetic-data demonstration, not a vault for sensitive notes.

1. Sign up. Your account gets two readable notes, a decoy owned by someone else in the same tenant, and a decoy owned by you in a different tenant. Only the first two appear.
2. Search for `budget`. The list and count narrow to one note. Export downloads that same authorized selection, including its body.
3. Try the foreign-owner, other-tenant and missing-ID probes. Each makes a real API request and gets the same sanitized not-found response. Knowing an ID does not grant access.
4. Open **Inspect agent changes**. Remove the owner check, remove the tenant check, omit a grant, use the wrong caller or request scope, or try to construct a grant directly. Inspect the recorded compiler diagnostics.
5. Select the `sorry` and changed-policy examples. These explain the checks that must surround Lean itself. Finish with the accepted control.

The agent panel contains reproducible **agent-style candidate patches**, not a transcript of an autonomous agent. Its evidence is generated during the image build. The public server never executes visitor-supplied Lean, shell commands or agent prompts. [Evidence JSON](https://private-notes-production.up.railway.app/evidence.json), [policy source](https://private-notes-production.up.railway.app/spec.lean) and [model source](https://private-notes-production.up.railway.app/model.lean) are available without signing in.

## The contract, in actual Lean

[`Spec.lean`](../examples/security/PrivateNotes/Spec.lean) defines the policy separately from the executable predicate. A note must belong to both the caller and the caller's current tenant. The full `CanRead` predicate also requires valid session facts: matching actor/tenant/generation, current generation, enabled account and unexpired session at the sampled request time.

This complete example is compiled by `npm run test:docs`:

<!-- lean-check: private-notes-ownership -->
```lean
import PrivateNotes
open PrivateNotes

example (caller : Principal) (note : Note)
    (selected : ownedPredicate caller note = true) :
    note.owner = caller.actor ∧ note.tenant = caller.tenant :=
  ownedPredicate_sound caller note selected
```

In [`Model.lean`](../examples/security/PrivateNotes/Model.lean), `ReadGrant τ facts caller` carries checked session evidence. The protected read requires a grant with matching indices; it cannot accept arbitrary JSON as a grant. `visible` filters by owner and tenant before sorting, searching, pagination or counting. All five read operations consume that scoped collection.

Nine exported theorem dependencies are audited. Together they establish predicate/selection exactness, authorized model-row provenance, the exact protected page, successful model evaluation under valid session facts, and **response noninterference**: keeping the caller's visible rows and session facts unchanged keeps the modeled response unchanged, even if hidden rows change. The statements quantify over arbitrary finite modeled snapshots and supported requests, not just the four demonstration rows.

These are completed kernel-checked proofs, with only Lean's standard `propext`, `Classical.choice` and `Quot.sound` axioms. No `sorry`, project-defined security axiom or native-computation axiom is accepted by the audit. Exactness and positive tests matter: returning no notes to anyone is private, but would not implement this application.

## What happens when an agent crosses the boundary?

| Candidate change | Observed result |
| --- | --- |
| Keep owner and tenant checks | The control builds; model assertions and axiom audit pass. |
| Omit the grant | Lean rejects the application type mismatch. |
| Use another caller's grant | Lean rejects the principal-index mismatch. |
| Reuse another abstract request scope | Lean rejects the scope-index mismatch. |
| Invoke the private grant constructor | Lean rejects the inaccessible constructor. |
| Remove owner or tenant from the executable predicate | The predicate's proof no longer establishes the separate policy. |
| Replace a proof with `sorry` | Lean compiles with a warning; the axiom audit rejects `sorryAx`. |
| Weaken the policy itself | The demonstrated protected-input digest check rejects the change. |

An agent can still *edit a file*. Lean does not control filesystem permissions, deployment credentials or CI configuration. If the agent can rewrite the policy, delete the tests and replace the verifier, a green build is meaningless.

For a real agent-assisted workflow, put the reviewed policy, required theorem statements, checker/toolchain configuration and verification harness under separate control. Give the agent a candidate workspace, not deployment credentials. A trusted gate must compare protected inputs against the reviewed baseline, rebuild the candidate, inspect theorem dependencies, run native integration tests, and approve the **same artifact** that will be deployed. Changes to the specification require separate human approval.

This repository demonstrates those rejection mechanisms; it does **not** configure an immutable CI gate, branch protection or an adversarial-agent sandbox. The digest case compares an edited candidate against the baseline read by the harness. That baseline and harness would need protection outside the agent's write permissions in a production workflow.

## How the proof reaches the native database boundary

```text
Opaque session cookie
  → native transaction: resolve current session and membership
  → checked ReadGrant indexed by those facts and caller
  → typed notes-read operation carrying that grant
  → SQLite query restricted to owner AND tenant
  → checked decoding and whole-result ownership certification
  → shared Lean search/count/export semantics → HTTP response
```

[`Notes.lean`](../adapters/native/LeanAppNative/Notes.lean) implements this path. The browser can provide a search, note ID and page bounds, but no owner or tenant. IDs and counts use canonical decimal strings at the wire boundary. Search is a literal, case-sensitive title substring, not SQL `LIKE` or interpolated SQL.

[`Auth.Store`](../adapters/native/LeanAppNative/Auth/Store.lean) resolves authority and runs the operation inside one `BEGIN IMMEDIATE` transaction. This deliberately conservative prototype serializes writers until the bounded request finishes. A committed membership change or revocation invalidates subsequent requests. It does not immediately cancel a request already using its authority, or retract a response already delivered.

The native host uses `Unit` as the model's abstract scope parameter, with an additional request-local lease checked by protected database entry points. The host retires that lease when dispatch exits, including failure paths. The abstract-scope rejection fixture demonstrates the model's type distinction; **it is not a proof of generative transaction scopes in native IO**. A native test separately checks that an old well-typed grant cannot read through a retired lease.

This is an example-specific proof-carrying read family. The existing generic `Binding.policy` still returns a success value without evidence; the request factory closes handlers over the checked grant and each read operation explicitly carries it. A general dependent-binding API and protected relational query language have not been extracted.

## The honest boundary

The model proves a property of modeled responses. Authentication's mapping from cookies and SQLite rows to session facts, SQL rendering, decoded-row provenance/completeness, FFI, native compilation and deployment remain trusted. The native adapter checks every decoded row and rejects the whole result on a scope mismatch, but this is not a proof of SQLite or of its query compiler.

Timing, logs, resource usage, infrastructure failures, arbitrary handler IO, administrators and direct database access are outside the theorem. The pure model's equality includes its structured errors/response flags; native HTTP status mapping is integration-tested, not a proved transport refinement. Native storage is bounded to at most 100 scoped rows; public fixture creation produces only two readable rows per account.

Fixture provisioning is a separate authenticated command. It intentionally creates synthetic decoys and discloses their IDs for the probes; that command is outside the five-read-operation noninterference claim. The public app offers no editor, sharing, admin or arbitrary SQL endpoint. The native test suite additionally provisions two real accounts into the same tenant and checks that their readable IDs remain disjoint.

Compared with the original design, this slice uses a concrete read family and in-Lean search over bounded scoped rows, rather than a general query DSL/SQL refinement proof. It uses `BEGIN IMMEDIATE`, not the proposed two-connection WAL-reader/revocation race. That race, generic scope generation and formal native refinement remain follow-up work. See [the design checkpoint](AUTHORIZATION_DESIGN.md#implemented-slice).

## Build and verify locally

Use the [native dependency layout](GETTING_STARTED.md): Lean 4.33.0, Node 22.13+, sibling LeanDB/LeanHttp checkouts and OpenSSL 3 development files. From the repository root:

```sh
npm ci
npm run build:notes
(cd adapters/native && lake build leanapp_notes leanapp_notes_checks)
adapters/native/.lake/build/bin/leanapp_notes_checks
npm run test:notes:http
npm run dev:notes
```

Open `http://127.0.0.1:4190`. SQLite persists at `.lake/notes.sqlite`; the native listener is loopback-only on 4191. The development gateway and the café use different ports/databases. To use an already available SQLite checkout, add `-Kleansqlite=/absolute/path/to/leansqlite` to the native `lake` command.

With the development server running, use `npm run test:notes:browser`. If Playwright has no installed browser, set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to a Chromium-compatible executable. The test opens a fresh profile, signs up a disposable account, exercises export/probes/login/logout and checks desktop/mobile layout. Against a hosted URL it additionally requires `--allow-mutations`:

```sh
npm run test:notes:browser -- https://private-notes-production.up.railway.app --allow-mutations
```

`npm run test:security` reruns the portable model, theorem-axiom audit and all eight rejection cases without starting a server. It retains candidate files, diagnostics and source hashes under `.lake/security/run-*`; `build:notes` copies a fresh receipt and the exact model/policy source into the public bundle. [Native tests](../adapters/native/NotesChecks.lean) and [HTTP tests](../tests/security/http.test.mjs) exercise same-tenant isolation, retired leases, rollback, strict input, query parity, restart persistence and revoked sessions.

## Host your own

`npm run package:notes` produces an allowlisted source snapshot under `.lake/releases/private-notes-*`, including the reviewed sibling dependencies and a SHA-256 source manifest. It excludes caches, existing databases, credentials and test accounts. The [Dockerfile](../deploy/notes/Dockerfile) builds Lean and the browser bundle on Linux and runs the proof, native crypto and native notes checks before producing a runtime image.

Upload that snapshot as a **separate service**. Configure Dockerfile builds, one replica, a persistent volume mounted at `/data`, `LEANAPP_DB_PATH=/data/notes.sqlite`, `PORT=8080`, an exact HTTPS `LEANAPP_ORIGIN`, and `/health/ready` as the health check. Railway deployment details and observed public checks are recorded in [the notes deployment receipt](../deploy/notes/README.md). Do not reuse the café's service or volume. The image also runs on a compatible Linux container host with persistent storage; a Heroku deployment has not been qualified.
