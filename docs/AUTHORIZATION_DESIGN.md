# From the authorization demonstration to an implementation

[Demonstration](AUTHORIZATION_DEMO.md) · [Architecture](ARCHITECTURE.md) · [Current interfaces](FULLSTACK_INTERFACES.md)

The [walkthrough](AUTHORIZATION_DEMO.md) is the acceptance specification. This document works backward from its visible results to the contracts needed to make them true, then gives the forward implementation order.

Status: a bounded protected-notes slice is implemented; the general interfaces below remain design proposals. Read [Private Notes](PRIVATE_NOTES.md) for actual APIs, proofs, checks and hosting. This does not establish a security theorem for every LeanApp application or change the existing café deployment.

## Implemented slice

[`PrivateNotes.Spec`](../examples/security/PrivateNotes/Spec.lean) and [`PrivateNotes.Model`](../examples/security/PrivateNotes/Model.lean) provide the separate policy, checked grants, certified reads, response semantics, provenance/exactness proofs and response noninterference theorem. The proofs work over arbitrary finite snapshots. Nine exported theorem dependencies are audited; the candidate harness rejects missing/wrong authority, owner/tenant predicate weakening, admitted proofs and an edited-policy digest.

[`LeanAppNative.Notes`](../adapters/native/LeanAppNative/Notes.lean) uses a concrete indexed read family. An additive transaction-aware auth host constructs the request's handlers with a checked grant; each read operation carries it to the native interpreter. Generic `Binding.policy` is unchanged. SQLite's mandatory owner-and-tenant filter is followed by checked decoding and whole-result ownership certification; bounded search/count/export semantics execute in Lean. There is no general protected SQL DSL or formal SQL/decoder refinement theorem yet.

The abstract scope-index fixtures reject mismatched model scopes. Native assembly currently instantiates the brand with `Unit` and enforces lifetime with a checked, retired IO lease, not generative scope types. The transaction is `BEGIN IMMEDIATE`, holding off other writers through dispatch. This is stricter serialization than the proposed WAL read-snapshot race below; it does not implement that race test or immediate cancellation. Native checks cover two real same-tenant accounts, old-lease rejection, exception rollback, connection reuse and denial after committed revocation.

The [running guide](PRIVATE_NOTES.md) also distinguishes the authenticated synthetic-fixture command from the five proved read operations and explains why the agent's verifier must be protected independently. The rest of this document retains the broader target design so those missing steps remain visible.

## Work backward from the response

| Demonstration requirement | What must already be true underneath it |
| --- | --- |
| Alice's response contains only her studio notes | The response serializer consumes only results certified for Alice, studio and the request snapshot. |
| Search, export and count obey the same rule | Each operation derives from one scoped relation; filtering happens before ordering, pagination or aggregation. |
| Weakening the ownership predicate fails to build | Query construction has a semantic proof obligation, not just a phantom authorization parameter. |
| Missing or mismatched authority fails to build | The binding passes authorization evidence to a handler whose repository operations require that evidence. |
| Revoked sessions fail on subsequent requests | Authentication facts and protected reads belong to one real database snapshot, with request-local capabilities. |
| This works through HTTP and SQLite | Trusted boundary code faithfully maps cookies, storage rows and query plans to the checked model; integration tests exercise that mapping. |

The implementation therefore starts with the policy and query semantics. Starting with a notes UI would leave the central guarantee unresolved.

## 1. Fix the policy and observation boundary

For this example, a note has a stable ID, owner, tenant, title and body. Owner and tenant are immutable through the protected read API. There is no sharing, administrator bypass, ownership transfer or note-writing endpoint in the first version.

A valid model snapshot contains session/account facts and finite note rows. IDs are unique; stored values satisfy the chosen wire/storage bounds. The authenticated principal includes actor, current tenant and session generation. Authorization time is sampled once for the request.

The policy is:

```text
CanRead(s, p, n) = SessionValid(s, p)
                   ∧ n.owner = p.actor
                   ∧ n.tenant = p.tenant
```

The server verifies the cookie and resolves `p`; it never accepts a browser assertion that this actor/tenant is authenticated. In a proof, `SessionValid` concerns the modeled session facts. The connection between those facts and the real cookie/database remains a named host obligation.

Define `Visible(s, p)` as the policy-authorized rows in deterministic ID order. Supported requests are list, lookup, title search, count and a bounded JSON export. Public request fields can narrow the selection but cannot set its owner or tenant.

The observations modeled by the first proof are response status and structured body for those fixed endpoints. Cookies, timing, memory consumption, query plans, logs and failures of external infrastructure are outside that observation model. This is a bounded confidentiality property, not whole-system noninterference.

## 2. State the theorems before choosing an API

These are target statements in mathematical pseudocode, not Lean declarations with unfinished proofs.

### Returned data is authorized and comes from the database model

```text
For every valid snapshot s, authenticated principal p and supported request q:
  if handleModel(s, p, q) succeeds,
  every returned note view is project(n) for some n in s.notes
  such that CanRead(s, p, n).
```

The provenance condition matters: attaching an owner field to an arbitrary payload does not prove where the payload came from. `project` must explicitly name the released fields, and the serialization path must preserve that projection.

### The implementation returns the permitted result

Specify the exact result of each operation as a function of `Visible(s, p)`. Lookup finds the matching visible ID or returns not-found. Search is a literal, case-sensitive substring of the title. Count and export use the same selection. Pagination uses stable IDs and applies only after scoping and search.

Prove the query interpreter agrees with these definitions and that valid authorized model requests within the bounds succeed. This supplies completeness within the requested page/export bound and prevents an always-empty or always-denying implementation from passing the security gate.

### Hidden rows do not affect the modeled response

```text
If s1 and s2 are valid snapshots with the same authorization facts for p,
the same authorization time, and Visible(s1, p) = Visible(s2, p), then
  observe(handleModel(s1, p, q)) = observe(handleModel(s2, p, q)).
```

This is the response noninterference target for the five modeled read operations. It catches counting hidden rows, taking a global limit before filtering, and distinguishing a foreign ID from an absent ID. It does not assert that SQLite will take equal time or encounter the same resource failures on the two physical databases.

All target proofs must be completed without `sorry`, project-defined axioms asserting security, or native-computation axioms substituting for the property being claimed. Inspect transitive axiom dependencies and review the statements themselves; a theorem can be valid and still express the wrong policy. Pin the Lean toolchain and checker configuration. [Lean's proof-validation guidance](https://lean-lang.org/doc/reference/latest/ValidatingProofs/) explains why checking a statement's meaning is separate from checking its proof.

## 3. Carry evidence through the binding

Today, [`Policy`](../engine/LeanApp/Binding.lean) returns `CallResult Unit Empty`. `Binding.toRoute` gates the handler on success but does not pass evidence into it. A [`ReadCapability`](../engine/LeanApp/Capability.lean) distinguishes read operations from writes; it does not establish an ownership theorem for the interpreter.

Prototype an additive evidence-carrying binding in the example. Its authorization result is dependent on the validated input, authenticated principal and transaction scope. The handler receives that result explicitly. Keep the existing binding API compatible while this contract is tested.

Illustrative shape:

```text
authorize : AuthFacts τ p → Input → Authorized (Grant τ p input)
handler   : (input : Input) → Grant τ p input → ProtectedProgram τ p Output
```

`Authorized` here denotes an authorization success/error result, not a promise about the existing alias with that name. The eventual Lean signatures must spell out all dependencies and error channels.

For private notes, a grant authorizes reading the caller's portion of the notes collection. It is indexed by transaction scope, principal, collection and read action. It is not a grant to read every row in that table. Lookup and search can vary their selector within that scope; row-level authorization is established by the scoped query and its result certificate.

No grant has a `Wire`/`FromJson` instance, a public unchecked constructor, a default instance, or a conversion from a Boolean. A checked constructor derives evidence from validated session facts. Public constructor privacy is an API boundary, not protection against malicious code running inside the trusted server.

## 4. Make the protected repository a narrow language

The example's handlers use a restricted, interpretable read program. Its operations accept a notes scope and return certified note results. It provides no raw connection, unrestricted `DbM`, arbitrary SQL, network action, logging action or `MonadLift IO`.

Illustrative repository shape:

```text
scope     : ReadScope τ p Notes
base      : scope → ScopedQuery τ p Notes
narrow    : ScopedQuery τ p Notes → NoteFilter → ScopedQuery τ p Notes
fetch     : ScopedQuery τ p Notes → ProtectedProgram τ p (CertifiedNotes τ p)
lookup    : scope → NoteId → ProtectedProgram τ p (Option (CertifiedNote τ p))
```

Start with a small query representation: an owner-and-tenant base scan, literal title filtering, ID lookup, stable ordering and bounded pagination. A constructor establishes that every selected row belongs to the source relation and satisfies `CanRead`. Narrowing preserves this property. Any permitted disjunction stays inside the narrowing predicate: `scope AND (a OR b)`, never `(scope AND a) OR b`.

The reference interpreter proves soundness and exact results for this representation. It operates on the model snapshot and can be used by tests. The native interpreter receives the corresponding real transaction through trusted host code; handlers never receive the model's unrestricted row store or a native handle.

Count and export are interpretations of the scoped relation, not independent raw-table helpers. Initially compute them from the same bounded, checked rows. A later SQL aggregate optimization needs its own correctness argument: checking an aggregate's owner field cannot establish that its input rows were authorized.

Keep note payloads inside certified results until the fixed response encoder releases them. The encoder is tied to the current request's principal and operation. Do not add an unrestricted “send any bytes” effect to the protected handler language.

A restricted program plus reviewed module dependencies makes the proof manageable. It is not a sandbox for arbitrary Lean plugins. Trusted code can import escape hatches, manufacture claims through [`TrustedNative.issueContext`](../engine/LeanApp/Context.lean), or capture secret data in a callback. The qualified endpoint assembly must exclude those paths from its protected application modules and explicitly review its interpreters and encoders.

## 5. Bind the scope to an actual transaction

[`Service.withAuthenticated`](../adapters/native/LeanAppNative/Auth/Store.lean) currently checks the session and calls application code under one admitted connection callback. It does not start a single SQLite transaction enclosing both steps. Callback ownership in one process is not snapshot isolation from a second database connection.

For this example, a new host wrapper must own the complete sequence:

```text
decode request and verify cookie shape
  → acquire the runtime-owned connection
  → begin a read transaction
  → sample authorization time; the first auth read establishes the snapshot
  → resolve current session/account facts in that snapshot
  → construct checked scope and interpret the protected read program
  → finish stepping queries and materialize the bounded certified result
  → end the transaction and retire its lease
  → encode the response for the same request
```

Check the token digest and CSRF/origin rules through the existing auth facilities. Resolve authoritative facts inside the transaction, not by trusting an earlier session lookup. A native adapter failure or a failure to end the transaction successfully prevents release of the response. No lazy cursor or streaming export escapes the transaction in this version.

Use a fresh abstract transaction index to reject mixing scopes in typed application code. Also enforce a host-owned runtime lease checked at every interpretation entry, retired on success and failure. A type parameter alone is not a lifetime system: Lean values are duplicable, and a polymorphic callback can package an existential value or retain a closure. The runtime must prevent such a retained value from opening new database work after its lease ends. Releasing already-materialized data for the original request is different from performing another read.

The chosen revocation semantics are snapshot-based. In WAL mode, a reader can retain an earlier view after another connection commits changes; this is documented [SQLite behavior](https://www.sqlite.org/isolation.html). A request whose authorization snapshot is established after revocation commits must fail. A request authorized in an earlier snapshot may complete, even if its response is sent later. Expiry is likewise checked at the sampled authorization time. Stronger cancellation or per-chunk reauthorization is a separate feature.

Use a private-cache connection with `read_uncommitted` disabled. Do not write through the same connection during this read program. Test the actual begin/read/end implementation and journal configuration. Future authorized writes need a separate transaction/revalidation design; the read scope does not authorize them.

## 6. State what the native adapter must preserve

The native query must bind owner and tenant from the scope, never the request body. ID/search parameters are bound values. A list/search query's logical structure is:

```sql
SELECT id, owner, tenant, title, body
FROM private_notes
WHERE owner = ? AND tenant = ? AND <narrowing predicate>
ORDER BY id
LIMIT ?;
```

This is a structural sketch, not SQL to paste verbatim. Generate identifiers and operators from the closed query representation; bind values separately. An arbitrary SQL string is not a certified query.

Decode rows with checked field types. Before releasing any result, check every row's owner and tenant against the scope and reject the whole operation on a mismatch. Do not silently drop suspect rows and report success: that can disguise an adapter bug and produce inconsistent counts/pages. This guard establishes ownership for the decoded values; it does not prove that SQLite selected exactly the right rows or that the decoder preserved their original contents.

The initial native soundness claim is therefore conditional on faithful query execution, row decoding and host snapshot binding. Keep those obligations visible beside the model theorem. Do not add an axiom declaring the SQL renderer correct to make that gap disappear.

Qualify the adapter against the pure interpreter using adversarial fixture data. Choose a concrete search operation with matching Unicode and case semantics rather than assuming SQL `LIKE` matches Lean string search. Reject NUL-containing text at boundaries, pin integer ranges and compare deterministic ordering, empty results, page boundaries and export limits. Use literal search parameters containing quotes, percent signs and underscores to catch interpolation or wildcard mistakes.

Finally, introduce a deliberate renderer mutation that removes a scope clause. Lean may still compile that trusted adapter. The native checks must detect the mutation and fail the release gate. This demonstration separates proof coverage from integration coverage instead of claiming that one replaces the other.

## 7. Reuse the existing stack without overstating it

| Existing component | Reuse | New obligation |
| --- | --- | --- |
| [Principal/context](../engine/LeanApp/Context.lean) | Server-issued identity vocabulary. | Bind checked authority facts to the protected transaction; claims alone are not proof of authentication. |
| [Bindings](../engine/LeanApp/Binding.lean) | Typed inputs/errors and explicit publication. | Pass dependent authorization evidence rather than discarding it as `Unit`. |
| [Capabilities](../engine/LeanApp/Capability.lean) | Explicit interpreter boundary. | Restrict protected handlers and establish repository semantics. |
| [Native authentication](../adapters/native/LeanAppNative/Auth/Store.lean) | Username/password sessions, generation checks and private access administration. | Resolve authority and read notes in one real transaction; enforce lease retirement. |
| [Café queries](../adapters/native/LeanAppNative/Cafe.lean) | Working owner-and-tenant filtering pattern. | Prove the new query model, then qualify its SQLite interpretation. |
| [HTTP host](../adapters/native/LeanAppNative/Auth/Http.lean) | Exact origin/CSRF checks, approved routing and sanitized errors. | Assemble protected handlers without exposing native connection capabilities. |

Keep LeanDB and LeanHttp independent. Begin the database adapter in the LeanApp example. If the existing transaction API cannot support the required snapshot lifecycle, make a separately scoped LeanDB change; do not move its source into this repository. The browser is a consumer of the protected API, never an issuer of authorization evidence.

## Forward implementation order

These are dependency gates derived from the demonstration, not a claim that implementation has started. Work status belongs in Beads.

| Stage | Deliverable | Exit gate |
| --- | --- | --- |
| A: executable specification | Private-notes policy, valid snapshot model, exact endpoint observations and the four-row fixture. | Positive owned reads, owner/tenant collisions, foreign/missing equivalence and expected search/count/export results execute. |
| B: proofs and scoped query core | Checked grants, restricted query/program types, reference interpreter, result certification and fixed encoders. | Soundness, exact-result and modeled noninterference proofs pass; weakening owner/tenant constraints cannot satisfy the contract. |
| C: binding boundary | Example-local evidence-carrying binding and a closed protected handler surface. | Missing/wrong caller, resource, action and transaction evidence is rejected; no public JSON grant constructor or IO lift exists. |
| D: SQLite interpretation | Native scoped repository, real authorization/read transaction, checked decoding and lease lifetime. | Reference/native parity, renderer-mutation detection, exception cleanup, expired-lease rejection and deterministic two-connection revocation checks pass. |
| E: HTTP and presentation | Fresh fixture runner, five approved read operations and minimal two-profile React UI. | Walkthrough passes through real HTTP/browser requests; counts, exports, forged inputs and stale sessions are checked. |
| F: qualification and reuse | Reviewed theorem statements/dependencies, trusted-source inventory and reproducible evidence. | Every acceptance row in the walkthrough has an artifact; only then consider extracting generic APIs into LeanApp. |

Suggested initial source roots are `examples/security/` for the pure model and handler experiment, `tests/security/` for proofs and rejection fixtures, and an example-specific module in `adapters/native/` for SQLite/HTTP. These paths are proposed, not existing modules to import. Do not create a generic policy DSL, ACL-sharing system, UI editor or broad framework migration before stages A–C establish a useful contract.

The first implementation task is small enough to review independently: write `CanRead`, `Visible` and the five pure endpoint functions; prove their disclosure and response properties over arbitrary valid snapshots. No SQLite, React, new authentication system or deployment is needed to establish that foundation.
