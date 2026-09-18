# Demonstration: private notes with proof-carrying access

[Documentation](README.md) · [Private Notes guide](PRIVATE_NOTES.md) · [Current authentication](AUTH.md)

Alice's private notes should remain private when a developer adds search, a count, or an export endpoint. The demonstration shows that requirement becoming a checked contract between the API server and its database access layer.

Status: original demonstration specification, written before implementation. A bounded implementation now exists: use the [Private Notes guide](PRIVATE_NOTES.md) for the actual app, nine audited theorem dependencies, eight rejected candidate patches and native/browser checks. The broader scenes below remain acceptance targets, not a claim that every proposed API or race test is implemented. Code-shaped excerpts in this document are still illustrative; actual source and diagnostics are linked from the guide. The café's deployment and its proof claims are unchanged.

The hosted slice creates per-account synthetic fixtures and provides direct API probes. Its native tests also use two real accounts in the same tenant. It uses a concrete proof-carrying read family, an IO lease and `BEGIN IMMEDIATE`; it does not yet provide a generic query DSL, generative native scope proof or the WAL-reader revocation race in scene 6.

## The claim the audience should remember

> Every note disclosed through these protected endpoints belongs to the authenticated caller and their current tenant, under the authorization snapshot used for that request.

The endpoint cannot request protected data without authorization evidence. The protected query implementation must also prove that the data it returns satisfies the ownership policy. Evidence is indexed by the caller, protected resource, permitted action and request transaction; a generic `isAuthorized : Bool` is insufficient.

This concerns application-visible access through the demonstrated endpoints. SQLite may scan database pages containing other users' rows. The trusted authentication/storage code, database administrator and operating system can access data outside this API. The demonstration does not claim to prevent those reads.

## Set the stage

Allow roughly eight minutes. Show a small notes app, two separate browser profiles, and the corresponding Lean source. Use ordinary React for the presentation so the audience can see that the security argument lives in the domain and server, independently of the UI language.

Start from a fresh, local fixture database. The fixture administrator provisions Alice and Bob into the same `studio` tenant; this is test setup, not a public tenant-selection endpoint. Alice is currently authorized for `studio`, not `archive`. Keep a historical row owned by Alice in `archive` to expose a missing tenant check.

| Note ID | Owner | Tenant | Title | Body marker |
| --- | --- | --- | --- | --- |
| 101 | Alice | studio | Launch budget | ALICE-DEMO-101 |
| 102 | Alice | studio | Garden notes | ALICE-DEMO-102 |
| 201 | Bob | studio | Launch budget | BOB-DEMO-201 |
| 301 | Alice | archive | Launch budget | ARCHIVE-DEMO-301 |

These markers are synthetic test data. IDs are deliberately visible to the presenter: privacy must survive an attacker knowing an ID. Generate disposable credentials during fixture setup; do not commit passwords or use the hosted café's accounts/database.

The first app is read-only apart from authentication. Notes are seeded by the fixture. A note editor would introduce write-policy obligations that this demonstration does not need.

## 1. Start with ordinary behavior

Sign in as Alice. Her list contains 101 and 102, and her count is two. Search for `budget`: she gets 101 and a count of one. Export her notes as a bounded JSON download: it contains exactly 101 and 102, including their real bodies.

In the other browser profile, Bob sees 201. He cannot see Alice's notes even though he shares her tenant. Alice cannot see 301 even though she owns it, because its tenant differs from her current authority.

Presenter line: “The policy is both owner and tenant. Being logged in, or merely belonging to the same workspace, is not enough.”

Show the single policy definition in Lean. Do not begin with tactics or framework assembly code.

```text
CanRead(snapshot, caller, note) :=
  SessionValid(snapshot, caller)
  ∧ note.owner = caller.actor
  ∧ note.tenant = caller.tenant
```

`SessionValid` includes current account/session generation, enabled state and expiry at the request's authorization time. Authentication establishes the caller from the server's session store; the browser does not supply a trusted actor or tenant.

## 2. Bypass the UI

While signed in as Alice, request note 201 directly, then request an absent ID. Both return the same sanitized not-found status and body. Repeat with 301. Submit forged owner/tenant fields and verify that the strict request codec rejects them: these endpoints accept a note ID or search criteria, never authority claims.

Inspect list, search and export responses. Neither `BOB-DEMO-201` nor `ARCHIVE-DEMO-301` appears. Search counts and pagination describe only Alice's visible collection.

Presenter line: “Hiding a button did not enforce this. We just called the API directly.”

These are HTTP tests. They establish the behavior of the running fixture, not a universal theorem and not identical timing for missing versus inaccessible notes.

## 3. Add an endpoint and forget authorization

Switch to the editor. Introduce a bulk-export handler using the protected repository API. First omit its authorization scope.

```text
exportNotes request := Notes.export request.filter
```

Check this definition against the registered handler type, so an accidentally partially applied function cannot pass. The build must reject the handler because it cannot obtain the protected query/result without a notes-read scope. Then use a scope for another principal, another resource, or a different transaction. Each attempt must be rejected for the intended type mismatch, with a compiling control case beside it.

Repair the handler by passing the scope supplied by its authorized binding:

```text
exportNotes scope request := Notes.export scope request.filter
```

Show that the handler never receives a raw connection, unrestricted `DbM` or an IO-lifting operation. It can narrow its permitted notes, but cannot ask this capability for the entire table. Calling the low-level host adapter from arbitrary trusted Lean code is outside this contract; the application-module boundary is part of the design.

Presenter line: “A new endpoint has to explain why it may read this data. It cannot just forget the check.”

## 4. Try to weaken the query

Inside the checked query layer, change `owner AND tenant AND search` into `owner AND search`, or into `owner OR search`.

The query constructor's proof obligation must fail. A valid query returns rows satisfying the complete policy; the weaker predicate does not establish that fact. The same-tenant Bob row and other-tenant Alice row make both mistakes visible in executable tests too.

Show the intended obligation, followed by its completed proof in the eventual implementation:

```text
For every row selected by this scoped query:
  the row belongs to the selected snapshot
  and CanRead(snapshot, caller, row).
```

Do not imply that deleting a clause from an arbitrary SQL string necessarily causes a Lean type error. The compiled rejection is about the checked query representation. A defect introduced in the native SQL renderer must fail separate adapter qualification; that renderer is initially trusted, not formally verified.

Restore the safe constructor. Add search using a narrowing combinator. Export and count consume that same scoped query rather than reopening the table. The application author does not repeat an ownership proof in every endpoint.

## 5. Show what was proved

Open the theorem beside the implementation. It quantifies over every valid modeled database snapshot, caller and supported request, rather than enumerating Alice and Bob.

The first theorem is disclosure soundness: every returned note is the public projection of a row in the snapshot that satisfies `CanRead`. Requiring a grant is not, by itself, this theorem.

Also show that list/search return the expected permitted rows and that lookup finds an existing owned note. An implementation that always returns an empty list would satisfy “no unauthorized rows” while being useless.

For the model's list, lookup, search, count and export, the stronger target is response noninterference: if two valid snapshots agree on Alice's visible rows and authorization facts, changing Bob's hidden notes cannot change Alice's modeled response. This covers more than accidentally displaying a body; it catches an unscoped count or limit. It does not include execution time, resource use, logs or arbitrary browser behavior.

Presenter line: “These tests exercise the integration. This proof covers all inputs to the model. The adapter must still implement that model faithfully.”

Proofs are erased from compiled programs. Runtime identity checks and query parameters remain; no proof certificate is sent to SQLite. See [Lean's treatment of propositions](https://lean-lang.org/doc/reference/latest/The-Type-System/Propositions/).

## 6. Revoke access without making a false promise

Use a fixture-only administration control to revoke Alice's session. Wait for the revocation transaction to commit, then start a new request with her old cookie. The server denies it before exposing any note. Reusing a stored client-side result or sending the old grant's JSON representation cannot recreate authority; grants have no public wire decoder.

For the concurrency test, pause a request after it has established its authorization snapshot. Commit revocation through a second database connection, then resume the old request. Under the proposed snapshot policy, that already-authorized request may finish; a request taking its snapshot after revocation must fail.

Show this distinction explicitly. A proof about an earlier snapshot is not a promise of immediate cancellation, and revocation cannot retract a response already delivered. A grant from one transaction cannot authorize database work in a later transaction, even if the public actor/tenant values are unchanged.

End the walkthrough with the corrected search/export endpoint and a green verification run. Show real compiler diagnostics and actual test results only after those artifacts exist.

## What makes the demonstration ready to present

The acceptance evidence must connect each scene to an artifact:

| Visible result | Required evidence |
| --- | --- |
| Alice receives her real notes | Positive model/native/browser checks, including bodies and ordering. |
| Bob and archive rows stay hidden | Universal modeled disclosure theorem plus real API owner/tenant collision tests. |
| Missing or mismatched authorization fails to build | Separate rejection fixtures with compiling controls and expected diagnostics. |
| Search/export preserve the policy | Query-construction proofs, modeled response noninterference and native response parity. |
| Revocation has a defined boundary | New-request denial and a deterministic two-connection snapshot race test. |
| The proof claims match the program | Reviewed theorem statements and axiom dependencies, with explicit native trust assumptions. |

Treat the table as the full demonstration's acceptance criteria. The [current guide](PRIVATE_NOTES.md) distinguishes completed model/native checks from the remaining generic-query and two-connection race work. A green documentation check validates navigation, not security.

## Two follow-on demonstrations

A tenant dashboard can show why authorized rows are only the beginning: a join or total must not reveal another tenant's customers or revenue. Derive reports from scoped relations and prove that changing hidden tenant data leaves the report unchanged. This requires join/aggregation semantics beyond the private-notes example.

A two-person approval workflow can carry authorization into a write: release an expense only with approvals from distinct authorized people, both bound to the exact expense revision and amount. Editing the expense invalidates the earlier approval evidence. The next proof obligation is that the transactional transition enforces those facts; it does not establish that a payment provider actually moved money.
