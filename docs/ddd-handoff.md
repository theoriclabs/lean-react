# LeanReact Partiful handoff

Updated 2026-09-30. Changes are uncommitted. Root toolchain remains **4.33.0**;
root package has no LeanDB, LeanAPI, SQLite, or crypto dependency. DDD-LR-01 portable
acceptance is qualified. DDD-LR-02..04 have the working Partiful surfaces and local
acceptance evidence below; their broader limitations and release qualification
remain open. No four-ticket completion claim.

## Compiled public surface

Import `LeanApp.Domain` for portable authoring and `LeanReact.Domain` for views.
`tests/domain/Partiful.lean` is the unchanged shared target Domain source;
`PartifulViews.lean` changes only its import to that fixture. Both compile.

- `Name`, `Title`, `Text`, `Email`, `Password`: private checked String values,
  `.parse : String → Ontology.Validation T`, `.value`. Password has no Repr.
  Canonicality is an actual proof field. `T.parse_value` is kernel checked.
  Instant stores exact signed-64-bit UTC epoch seconds with a range proof;
  `Instant.parse`, `ofEpochSeconds`, `ofEpochSeconds_value` are compiled.
- Native and browser use the SAME Lean parsers. Normalization/UTF8 bounds are
  pure portable scalar algorithms; integers use shared
  `Ontology.JsonWire.decimalNat?` / `decimalInt?`, never JS Number.
- `Ref T` reuses nominal `Ontology.EntityId T`. `Ref.parse key (scope := "default")`
  and `refCodec` enforce canonical positive signed-64-bit keys. General Ontology
  IDs still have unrestricted logical inhabitants; no universal database codec
  round-trip law is asserted for them. Native scope conversion must reject
  unsupported scopes.
- `Members T` is a zero-data declaration marker with NO Wire instance.
  `Disclosure α` has visible/hidden. Hidden is exactly canonical Ontology unit
  `{"tag":"hidden","value":null}`: no names, count, IDs or denial reason.
  Non-null hidden values and unknown keys reject.
- `@[entity] structure` derives storage-only Entity/Domain metadata, lawful
  EditableField lenses, typed FieldPaths, MemberField handles, Field enum and
  HasRecord using the existing Ontology.RecordDescriptor. Entity has NO Wire.
  `Entity.recordRepresentation` is a privileged INTERNAL codec excluding Members,
  used by the portable reference backend; never publish it.
- `deriving Domain` supports flat monomorphic records and payload-free closed
  enums, including genuinely empty Error enums. It derives Wire only for public
  value declarations. Dependent/inherited/polymorphic/payload declarations reject
  explicitly. Metadata preserves defaults, reference/member targets and scalar
  editor kinds. Field names are labels, not password/email widget evidence.
- `unique% Person.byEmail := email` generates typed Unique/FieldPath metadata and
  adds `emailTaken` to generated create/auth signup and touched-field change
  constraints and closed Errors. A change never receives unrelated unique failures.
- `auth% account : Person using emailPassword(email)` derives the two typed
  contracts, inputs, errors and native signUp/signIn request hooks. Profile must
  currently have exactly name:Name and email:Email. Crypto/credential/session
  execution remains API-owned. Memory explicitly refuses native authentication.

## Typed native resource ABI

`engine/LeanApp/Domain/Resources.lean` exports:

```lean
structure ResourceFamily where
  entity : Type → Type 1
  member : Type → String → Type → Type 1
  projection : {P T V : Type} → {name : String} → member P name T → Ontology.FieldPath T V → Type 1
  auth : {T : Type} → entity T → Type 1
class HasEntityResource (family : ResourceFamily) (T : Type) where
  witness : family.entity T
class HasMemberResource (family : ResourceFamily) (P : Type) (field : String) (T : Type) where
  witness : family.member P field T
```

Column/auth additions now compile in the portable library and original target. `HasProjectionResource
family P T member storage field V` (requires `EditableField T field V`) contains
`family.projection storage EditableField.lens.toFieldPath`. The dependency on the
ACTUAL member storage permits a DB family to demand a native field, fieldTy equality
and getter agreement tied to that exact relation.target.entity dictionary.
`ProjectionF.members relation path selection` carries this witness;
`Projection.memberField relation "name"` infers it. Arbitrary-path Projection.members
is portable-only. Generated requirements currently include direct target columns
of declared members; native_schema% now synthesizes the matching DB capabilities.

`HasAuthResource family T storage` contains `family.auth storage`; signUp/signIn
requests carry storage then authentication. This is anchored to the same profile
Entity witness, rather than an independent potentially incoherent profile store.
Native API owns credentials and session creation. `Account.signUpProfile`,
`.signUpPassword`, `.signInEmail`, `.signInPassword` expose typed preparation data;
the generated corresponding `account.signUp.profile/.password` and
`account.signIn.email/.password` accessors are available before Flow.now/writer
admission. No flow execution is needed for password preparation.

The single IR is now family-indexed. Public abbreviations preserve portable
call sites with a final default family parameter:

```
Flow kind Scope Error Output (resources := portableResources)
Request Scope Error kind Output (resources := portableResources)
Policy Scope (resources := portableResources)
Projection Scope Output (resources := portableResources)
MemberHandle Scope Parent Target (resources := portableResources)
Algebra m kind Scope Error (resources := portableResources)
```

Underlying inductive names are FlowF/RequestF/PolicyF/ProjectionF; these are NOT
another semantics. Explicit constructor patterns must use those names.
Entity requests now carry `storage : resources.entity T` after their portable
Entity dictionary. `MemberHandleF` contains name and
`storage : resources.member Parent name Target`, retaining the exact typed edge
witness. `Row.membersField` requires HasMemberResource; arbitrary-path Row.members
is explicitly portable-only.

Each generated operation exposes:

```
op.Requirements resources : Type 1
op.Requirements.infer [required typed capability instances] : op.Requirements resources
op.portableRequirements
op.flowWithResources requirements actor input
op.flow actor input                         -- portable specialization
op.bodyWithResources requirements actor input
op.body actor input                         -- same portable specialization
```

`Operation` has dependent Requirements/portable/bodyWithResources fields;
`.body` is a function specializing that ONE body, not a second hand-written body.
Requirements currently include the authoring namespace's declared entities,
members, coherent direct target-column projections and operation-owned auth. Native app assembly can generate `op.Requirements.infer`, with no
app-owned witness record/DTO or runtime TypeId-to-Type recovery. Imported entities
outside that namespace need a future precise dependency closure; synthesis fails
rather than inventing storage capabilities.

Working native family: `LeanDb.Domain.storageResources S`. It supplies entity,
member, projection and an uninhabited DB-only auth slot (`ULift Empty`).

The optional fixture consumes ORIGINAL Partiful types through native_schema%,
synthesizes host/RSVP/page requirements, and compiles generic findHook/containsHook
from actual dictionaries (including existential Edge). DB's ProjectionStorage
column carries the exact relation.target.entity and source_agrees/getter proofs.
native_schema% generates the HasFieldProjection providers used by the generic
HasProjectionResource instance. projectHook uses ProjectionStorage.project,
selecting only the proven column. No fixture-owned providers/rows or unsafe casts.

Fresh Storage/Witness/Resources/Schema/Access plus NativeWitness **PASS**. The earlier
HasFieldProjection candidate indexing failure is resolved by DB's explicit s/T/field
lookup with dictionary/path outputs checked for equality. The partial findRequest
selector remains a compiler fixture, not a complete native algebra. API's native
family replaces only auth and owns whole app/runtime assembly.

## Flow semantics and trust

`Flow.run [Monad m] : Algebra m k Scope Error resources →
Flow k Scope Error A resources → m (Except Error A)` is total and universe
polymorphic (`m : Type → Type u`). Its algebra owns request, indexed membership
existence and projection. API must use this interpreter with its native family.
Policy.eval and Flow.mapError are also total.

Commands/queries generate Input, closed Error, ordinary Contract.Operation,
ordered nodes/effects/checks/named-constraint/source metadata and the body. Actor/time
are excluded from input. `require` returns genuine PLift proposition evidence; `require p else failure as
proof` exposes it as `proof.down` to subsequent authored proofs.
Selective Change patches use kernel-proved lawful lenses. Query writes and IO
are type errors. Guarded disclosure checks Policy BEFORE evaluating Projection.
There is no public Flow.project. Policy uses indexed membership with no host
exception. There is no Request.contains constructor; membership reads remain in the
policy algebra and cannot become unguarded authored protected queries.

Row/SignedIn/Viewer constructors are private and have NO Wire. Trusted.row /
signedIn / viewer are explicit trusted adapter assembly functions. Resolve live
rows inside the current rank-2 native snapshot/transaction. This is a trust
boundary, not a claim that malicious native Lean cannot call Trusted helpers.

`LeanApp.Domain.Memory` supplies nonempty typed reference semantics with actual
stored row decoding, uniqueness, exact pair sets, stable ID ordering, selective
patches, parent membership cascade, no denied projection evaluation and rollback
on late domain errors. Unsupported constraints/auth remain explicit infrastructure
faults. It is not a SQLite verification theorem.

## Derived UI and disclosure lifetime

form/button/screen, original actions syntax, total onError/onSuccess presentation,
fieldError .field, notice/go, page/heading/dateTime/paragraph/list/text and
exhaustive guestsView compile from the original target. Existing Forms/Resources/
DOM/Contract.Interpreter remain the implementation; no app service/validator stack.

`useDomainForm` retains raw JSON-shaped drafts, runs the exact checked codec,
keeps invalid values, refuses invalid submissions, claims the existing atomic Cell before validation to
prevent concurrent double calls, separates domain/framework failures, ignores obsolete auth
responses and dispatches success navigation/refresh. DomainForm.cancel invalidates
its submission token and releases pending state; unmount invalidates all replies.
With Shell.requestClient, that same ResourceRequest registers transport abort
cleanup; submit cancel/unmount and obsolete query actor generations abort fetch.
The shared browser assembly must supply this optional factory. Editor kinds/required flags
come from actual scalar type metadata (Password/Email/Text...), including renamed
fields. RouteInput derives nominal route parsing and bound refs are not editors.
Type-1 client dictionaries are captured in regular Type-0 Components.

ResourceScope keys contain nominal resource/actor plus auth/policy generations.
useScopedResource/ScopedTracker and derived screens reuse existing cancellation /
generation machinery; scope changes drop old data immediately. Refresh replaces
whole Disclosure; actor/logout remounts action state. No storage/shared-cache path
was introduced. Already legitimately delivered data cannot be revoked remotely.
Private/no-store HTTP enforcement and browser auth/CSRF rotation remain API-owned.

## Evidence and outstanding criteria

Passed: root library build (bounded LEAN_NUM_THREADS=2); unchanged target Domain
and Views compilation; populated Memory six-flow matrix/cutoff/failure precedence/
selective patch/rollback/cascade cases; scalar laws and native runtime edge cases;
actual LeanJS generation of checked scalar parsers, host parser/forms and the full
party screen; native/JS scalar output equality (including Unicode and exact values
beyond JS safe integers); optional current DB typed witness compilation.

Passed qualification: eight positive modules including seven scalar/default axiom
audits (standard Lean axioms only), populated native runtime, 27 compiler rejection
fixtures, two-process generation
byte equality, 17 mounted browser tests, and real generated DB witness compilation.
Browser cases include invalid retained drafts, concurrent pending calls, renamed/
default editors, duplicate email, bad credentials, auth-before-navigation, RSVP
refresh, host/date errors, cancel redirect, typed framework errors, whole disclosure
replacement, logout/old generations, and cancelled/unmounted submissions and cancel/resubmit reply races. A native
Flow-generated 12-row visibility matrix traverses HTTP codecs and the compiled
screen, including host-without-RSVP; denied bodies are exactly hidden/null and
projectionReads=0. These use a faithful in-process HTTP client fixture, not a live
native Partiful HTTP server.

Existing regressions: ontology/contract executable tests and seven rejections
PASS; compiler corpus/native parity/intrinsic/hooks/determinism **13/0**; existing
actions/React/resources/integration-resource JS tests **38/0**. Commands below.

Enum/default draft initialization now uses constant JSON with kernel-checked
codec equality (fixing the earlier Lean4.33 join-point panic). Custom typed editors
are provided by FormSpec.editor. Authentication success calls Shell.authenticationChanged
before navigation, enabling shared session/CSRF rotation.

Known implementation gaps excluded from completion claims: omitted wire defaults;
remaining native FK/invariant constraint obligations; generic cross-field invariant
registration; pinned release graph/fresh-clone qualification.
General imported-namespace resource closure and auth profiles beyond name/email
remain explicitly unsupported. Calendar input supports years 0001..9999 with
whole UTC seconds; full signed-64-bit epoch parsing/display remains exact. Scope invalidation prevents stale display. Transport abort is tested through
the optional requestClient factory. Native browser assembly and auth/CSRF rotation
are API-owned. The current coordinator reports original Main/native HTTP and
Chromium integration passing, including generated requestClient wiring and auth
invalidation. Those are peer receipts, not runs performed by this worker.

Toolchain: root stays 4.33.0. Coordinator's common API/DB/Domain 4.33 graph passes LeanJS ABI;
nightly changed Decidable representation and is not qualified for browser output.
No toolchain/dependency checkout download or release-local path was introduced.

## Latest operation/UI additions

`call callee actor input` composes that SAME family-indexed generated body, with
an exhaustive generated error map. Every callee constructor contributes
`calleeName_failureName` to the caller Error; a new alternative propagates and
breaks a missing handler. No universal error bag/Except String is involved.
Changed-field unique constraints now use the typed find's entity plus touched
fields; populated Memory collision/rollback and callee error tests pass.

`LeanReact.Domain.DateInput` provides pure UTC Gregorian calendar editor/display:
`epochDraft`, `editorText`, `formatEpoch`. Instant editors use datetime-local with
explicit UTC accessible label and second precision; wire remains exact epoch text.
Leap-date invalid input stays available to the shared Instant codec. Root DOM adds
InputType.datetimeLocal. Zero-only DOM fractions (e.g. .000) are accepted without
rounding; nonzero fractions remain invalid. Native and browser boundary tests pass.

Inspection: `#domain_inspect Partiful.reschedule` prints the generated FlowMetadata
and the ordinary Contract.OperationInfo input/output/error schemas,
including ordered node effects, touched fields, named constraint identities,
failures, source location and session-establishment footprint. Auth footprint and
requirements propagate through typed call; the actual native preparation of nested
auth callees is not claimed here.

Reproduce with bounded threads (no developer paths in release manifests):

```
python3 scripts/check-domain.py --db-source ../LeanDB --spec-source ../domain_driven_development
LEAN_NUM_THREADS=2 lake build
LEAN_NUM_THREADS=2 lake env bash tests/ontology/check.sh
LEAN_NUM_THREADS=2 lake env lean --run tests/Run.lean compiler
node --test tests/runtime/actions.test.mjs tests/runtime/react.test.mjs tests/runtime/resources.test.mjs tests/integration/resources.test.mjs
```

Integration checkpoint read before finalization: the coordinator reports native
eight-operation HTTP/SQLite acceptance exit 0 and Chromium acceptance 276 checks,
with unchanged authored source, requestClient wiring, bounded unauthenticated
refetch and actual obsolete-fetch abort. API/DB handoffs still contain older
chronological blockers; the coordinator's current checkpoint supersedes them.
Exact next integration step: finish API's final regression gates and consolidate
the linked acceptance receipts, then qualify a pinned optional release graph.
Further portable library work is explicit constraint/invariant metadata and
precise imported-namespace resource closure; do not silently broaden public errors.

Compiled and runtime-tested transport cancellation integration: `Shell.requestClient :
Option (ResourceRequest → Contract.Interpreter Action)` defaults to none.
`ScreenSpec.component client (requestClient := some factory)` and
`useDomainScreen ... (requestClient := some factory)` reuse ResourceRequest
for query cleanup and form cleanup. Generic JS factory:
`request => createContractInterpreter({ program, client, request })`.
The bridge registers an AbortController on that exact request's onCleanup;
no app-specific request DTO, parser, auth engine or resource hook is introduced.
All 17 mounted browser cases pass. This optional argument is required for actual
network cancellation; the coordinator reports API's generated assembly now supplies
it. Existing portable call sites remain compatible.

Derived onError additionally rejects named-variable catch-all match patterns,
including nested `match error with | fallback => ...`; use dot/qualified
constructor branches or genuine empty-type elimination. The rejection fixture
covers this bypass of the simpler wildcard check.

The derived handler must match its error argument directly (or eliminate that
argument's genuinely empty type). A match on a constant cannot disguise an
ignored Error; IgnoresError is an additional negative fixture.

## Final owned change inventory

- Added `engine/LeanApp/Domain.lean` and
  `Domain/{Scalars,Metadata,Deriving,Resources,Flow,Declarations,Memory}.lean`.
- Added `engine/LeanReact/Domain.lean` and
  `Domain/{Drafts,Scopes,DateInput,View,Screen}.lean`.
- Added `engine/LeanContract/Browser.lean`,
  `engine/adapters/leanjs-contract.mjs`, `scripts/check-domain.py` and this handoff.
- Added `tests/domain/{Axioms,Browser,Declarations,Evolution,Generate,Main,
  NativeWitness,Operations,Partiful,PartifulViews,Views}.lean`, `.gitignore`,
  `browser.test.mjs` and the 27 fixtures enumerated by `negative/expected.json`.
- Modified `engine/LeanContract/Operation.lean`, `engine/LeanOntology/Codec.lean`,
  `engine/LeanJS/{Compiler.lean,ABI.md}`, `engine/LeanReact/DOM.lean`.
  No manifest/toolchain/configuration changes. No staged files or commits.

Final current-source commands above all exit 0. Root build reports 47 jobs;
domain runner verifies the exact authored sources, eight positive modules,
populated runtime, 27 compiler rejections, two deterministic generation processes,
17 browser cases and five fresh DB bridge modules plus the generated native witness.
The ontology gate has seven intended rejections; compiler is 13/0 and existing UI
regressions are 38/0. `git diff --check` is clean. Generated artifacts/logs stay
under the fixture's ignored owned directories; no peer files were written.

Ticket boundary: LR-01's portable vocabulary/derivation acceptance is qualified.
LR-02's Partiful operations, closed guard/unique/callee failures, usable require
proofs, query restrictions and policy-first disclosure are qualified; general
constraint/invariant derivation and imported closure are open. LR-03's authored
Views, typed/default/custom editors, exhaustive error evolution and submit lifecycle
are qualified locally; omitted wire defaults and broader auth profile derivation
are open. LR-04's disclosure bytes, 12-case matrix, refresh/actor/logout invalidation
and transport cancellation are qualified locally. Native HTTP/cache/session behavior
is reported by API/coordinator's linked gates, not re-claimed as this worker's run.
Release packaging remains a cross-repository gate.
