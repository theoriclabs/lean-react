# P02 ontology and contract API

Implemented for Lean **4.33.0**, using only Lean/Std. Import `LeanOntology` and
`open Ontology` for domain foundations. Import `LeanContract` and `open Contract`
for operations and interpreters; that import also imports `LeanOntology`.
All library functions are pure or parameterized by a caller-supplied monad.
Only executable tests use `IO`. There are no native HTTP, database, React, or
compiler dependencies.

These are the actual explicit APIs. The proposed `Ontology.Record`,
`Ontology.Variant`, and `Ontology.Wire` deriving handlers from `VISION.md` are
**not implemented**. The canonical type class here is `Ontology.Wire`, whose
single field is `codec : Codec α`.

## Typed paths and optional replacement

`TypeId` has `packageName : String` and `name : String` and derives `Repr`,
`BEq`, and `DecidableEq`. These are explicit stable semantic names; they do not
automatically track Lean declaration renames. `HasTypeId α` has
`typeId : TypeId` and supplies canonical entity codecs.

`PathSegment` is one of:

```lean
.field (owner : TypeId) (name : String) -- semantic field identity
.key (name : String)                   -- wire object key
.index (value : Nat)
.variant (tag : String)
```

`FieldPathId := List PathSegment`. `FieldPath Source Value` has
`identity : FieldPathId` and `get : Source → Value`.

```lean
FieldPath.id : FieldPath α α
FieldPath.field (owner : TypeId) (name : String) (get : α → β) : FieldPath α β
FieldPath.comp (outer : FieldPath α β) (inner : FieldPath β γ) : FieldPath α γ
```

Composition reads outer then inner and appends path identities in that order.
It cannot follow an `EntityId` automatically: a service must resolve the ID first.

`Lens Source Value` extends `FieldPath Source Value` with
`set : Source → Value → Source`. `lens.toFieldPath` explicitly drops replacement.

```lean
Lens.id : Lens α α
Lens.field (owner : TypeId) (name : String) (get : α → β)
  (set : α → β → α) : Lens α β
Lens.comp (outer : Lens α β) (inner : Lens β γ) : Lens α γ
Lens.modify (lens : Lens α β) (f : β → β) (source : α) : α
```

`Lens.Laws lens : Prop` optionally supplies `get_set`, `set_get`, and `set_set`.
`Lens.id_laws` proves the identity lens lawful; `Lens.Laws.comp` composes two law
values. Using a path or lens never requires these proofs.

## Structured validation and drafts

`ValidationError` has `code : String`, `path : FieldPathId := []`, and
`params : List (String × String) := []` for localization arguments.
`ValidationErrors` is structurally nonempty:
`first : ValidationError`, `rest : List ValidationError := []`.

```lean
ValidationErrors.single (code : String) (path : FieldPathId := [])
  (params : List (String × String) := []) : ValidationErrors
ValidationErrors.toList (errors : ValidationErrors) : List ValidationError
ValidationErrors.append (a b : ValidationErrors) : ValidationErrors
ValidationErrors.prependPath (path : FieldPathId) (errors : ValidationErrors) : ValidationErrors

abbrev DecodeErrors := ValidationErrors
abbrev Validation α := Except ValidationErrors α
abbrev Validator α := α → Validation Unit

Validation.fail (code : String) (path : FieldPathId := [])
  (params : List (String × String) := []) : Validation α
Validation.prependPath (path : FieldPathId) (result : Validation α) : Validation α
Validation.map2 (f : α → β → γ) (a : Validation α) (b : Validation β) : Validation γ

Validator.check (code : String) (predicate : α → Bool) : Validator α
Validator.and (a b : Validator α) : Validator α
Validator.contramap (get : α → β) (validator : Validator β) : Validator α
Validator.atPath (path : FieldPath α β) (validator : Validator β) : Validator α
```

`Validation.map2`, product/collection decoders, and independent record field
decoders accumulate errors in input order. Ordinary `Except` monadic sequencing
stops at the first failed dependent step. An invalid object shape or unknown
key stops before decoding its fields.

`PatchField α` has `.keep` and `.set (value : α)`.
`PatchField.apply (patch : PatchField α) (previous : α) : α` applies that change.
For `PatchField (Option α)`, `.set none` clears while `.keep` preserves.
No form/editor state engine is included in P02.

## Scoped nominal references

`IdentitySpace` has a private constructor and public `value : String`.
`EntityId (Entity : Type u)` has a private constructor and public
`scope : IdentitySpace` and `key : String`. Both derive `Repr`, `BEq`, and
`DecidableEq`; equality includes the scope.

```lean
IdentitySpace.parse (value : String) : Validation IdentitySpace
EntityId.ofParts (scope : IdentitySpace) (key : String) : Validation (EntityId α)
EntityId.parse (scope key : String) : Validation (EntityId α)

Codec.entityId (identity : TypeId) (expectedScope : Option IdentitySpace := none)
  : Codec (EntityId α)
```

Scope and key must be nonempty; they otherwise remain exact, case-sensitive,
uninterpreted strings. Neither constructor checks row existence, authority, or
cross-instance resolution. The nominal parameter prevents assigning an
`EntityId Ticket` to an `EntityId User`, even when their representations coincide.

The wire object is
`{"type":{"package":"…","name":"…"},"scope":"…","key":"…"}`.
The decoder rejects a different type identity and optionally a different scope.
`Wire (EntityId α)` requires `HasTypeId α` and uses an unrestricted scope codec.
Applications own the uniqueness and consistency of their declared `TypeId`s.
An explicit scope restriction applies during decoding; encoding a value from a
different scope is possible and will not round-trip through that restriction.

## First-class codecs

`WireValue := Lean.Json`. A `Codec α` has:

```lean
schema : WireSchema
encode : α → WireValue
decode : WireValue → Validation α
```

`Wire α` supplies `codec : Codec α` for canonical use.
`Codec.canonical [Wire α] : Codec α` retrieves it. Every combinator accepts
ordinary codec values, so alternate encodings do not need competing instances.

```lean
Codec.encodeJson (codec : Codec α) (value : α) : String
Codec.decodeJson (codec : Codec α) (text : String) : Validation α
Codec.checked (codec : Codec α) (construct : α → Validation β) (project : β → α) : Codec β
Codec.xmap (codec : Codec α) (construct : α → β) (project : β → α) : Codec β
Codec.validated (codec : Codec α) (validate : Validator α) : Codec α
Codec.named (codec : Codec α) (identity : TypeId) (version : String := "1") : Codec α

Codec.string : Codec String
Codec.bool : Codec Bool
Codec.unit : Codec Unit
Codec.nat : Codec Nat
Codec.int : Codec Int
Codec.product (left : Codec α) (right : Codec β) : Codec (α × β)
Codec.option (codec : Codec α) : Codec (Option α)
Codec.list (codec : Codec α) : Codec (List α)
Codec.array (codec : Codec α) : Codec (Array α)
Codec.sum (left : Codec α) (right : Codec β) : Codec (Sum α β)
Codec.except (error : Codec ε) (success : Codec α) : Codec (Except ε α)
Codec.patch (codec : Codec α) : Codec (PatchField α)
Codec.map [Ord κ] (key : Codec κ) (value : Codec ν) : Codec (Std.TreeMap κ ν)
Codec.field (name : String) (codec : Codec α) (value : WireValue) : Validation α
```

Canonical instances exist for those primitive/container types, recursively
using canonical child instances, and for `EntityId α` as above. `Codec.Laws c`
optionally asserts `roundTrip : ∀ value, c.decode (c.encode value) = .ok value`.

`checked` and `xmap` retain the underlying schema. Use `.named identity version`
to declare a newtype or changed validation contract. Validators do not get
inferred from names or presentation metadata. `checked` validates decoded
values, not arbitrary values passed to `encode`; if public constructors admit
invalid inhabitants, the codec cannot claim an unconditional round-trip law.

Exact JSON formats:

| Lean value | JSON representation |
| --- | --- |
| `String`, `Bool`, `Unit` | JSON string, boolean, `null` |
| `Nat` | `{"tag":"nat","value":"9007199254740993"}` |
| `Int` | `{"tag":"int","value":"-9007199254740993"}` |
| `Option.none` | `{"tag":"none"}` |
| `Option.some x` | `{"tag":"some","value":…}` |
| Product | Exactly two array elements |
| List / Array | JSON array |
| `Sum.inl x` / `.inr x` | `{"tag":"left","value":…}` / `{"tag":"right","value":…}` |
| `Except.error e` / `.ok x` | Same left / right tags, respectively |
| `PatchField.keep` / `.set x` | Same none / some tags, respectively |
| `Std.TreeMap κ ν` | Array of `[encodedKey, encodedValue]` pairs |

Integer decoders reject JSON numbers, incorrect tags, leading zeros, negative
zero, exponents, whitespace, and other noncanonical decimal spellings.
`Nat` and `Int` are arbitrary precision throughout. Nested options preserve
every constructor, including `some none` and `some (some ())`.
Map decoding rejects duplicate **decoded** keys under the supplied ordering;
encoding enumerates the `TreeMap` in key order. Supply a sensible lawful ordering.

`JsonWire` contains the shared lower-level helpers `object`, `get`, `string`,
`stringField`, `tagged`, `checkTag`, and `uniqueNames`. `object keys value`
checks object shape and rejects unknown keys; it does not require every key.
`get`/`Codec.field` perform the missing-key check. `uniqueNames` rejects empty
or duplicate names.

## Records and variants without deriving

`RecordFields Source Value` describes object fields with
`schema : List (String × WireSchema)`,
`encode : Source → List (String × WireValue)`, and
`decode : WireValue → Validation Value`.

```lean
RecordFields.pure (value : β) : RecordFields α β
RecordFields.field (name : String) (codec : Codec β) (get : α → β) : RecordFields α β
RecordFields.map (f : β → γ) (fields : RecordFields α β) : RecordFields α γ
RecordFields.apply (functions : RecordFields α (β → γ))
  (values : RecordFields α β) : RecordFields α γ
RecordFields.product (left : RecordFields α β) (right : RecordFields α γ)
  : RecordFields α (β × γ)
Codec.record (identity : TypeId) (fields : RecordFields α α)
  (version : String := "1") : Validation (Codec α)
```

Build a record by starting with its constructor and applying each named field.
For example, this is the actual Tickets fixture:

```lean
def ticketFields : RecordFields Ticket Ticket :=
  (RecordFields.pure Ticket.mk)
    |>.apply (RecordFields.field "title" titleCodec Ticket.title)
    |>.apply (RecordFields.field "priority" Codec.nat Ticket.priority)
    |>.apply (RecordFields.field "owner" Codec.canonical Ticket.owner)

def ticketCodec : Validation (Codec Ticket) :=
  Codec.record ⟨"tests", "Ticket"⟩ ticketFields
```

`Codec.record` validates field names at assembly time. Its decoder requires
every declared field, including fields whose values are options, and rejects
unknown fields. To keep omission distinct from clearing, put `PatchField` in
the command type. There are no implicit defaults or permissive record modes.

Reflection is a separate capability. `ValueDescriptor α` has `identity : TypeId`
and `displayName : String := ""`. `RecordDescriptor α` has:

```lean
identity : TypeId
Field : Type
Value : Field → Type
fields : List Field
fieldName : Field → String
valueDescriptor : (field : Field) → ValueDescriptor (Value field)
get : (field : Field) → α → Value field
replace? : (field : Field) → Option (α → Value field → α) := fun _ => none
```

`record.path f : FieldPath α (record.Value f)` builds the semantic path.
`record.lens? f` returns replacement only when explicitly supplied.
`record.validate : Validation Unit` checks its enumerated field names.
`record.findField name : Option (SomeField α)` returns a checked existential
package with `Value : Type`, `descriptor : ValueDescriptor Value`, and
`path : FieldPath α Value`. It never casts an external string into a caller's
chosen field type. Dependent descriptor projections may need an explicit type
argument at polymorphic consumers, e.g. `(α := Nat)`, for instance synthesis.

`VariantDescriptor α` has:

```lean
identity : TypeId
Case : Type
Payload : Case → Type
cases : List Case
tag : Case → String
payloadDescriptor : (variant : Case) → ValueDescriptor (Payload variant)
inject : (variant : Case) → Payload variant → α
select : α → (variant : Case) × Payload variant
```

`Codec.variant variant (payload : (tag : variant.Case) → Codec (variant.Payload tag))
(version : String := "1") : Validation (Codec α)` checks nonempty, unique tags,
then encodes `{ "tag": stableTag, "value": encodedPayload }`. Unknown tags
are errors. Payloadless constructors can use `Unit`, whose payload is `null`.
`VariantDescriptor.Laws` optionally states `inject_select`, `select_inject`,
and `complete` (the selected case occurs in the enumeration). Enumeration
completeness and constructor inverses are the descriptor author's responsibility
unless those laws are supplied.

`TypeId.toJson`, `ValueDescriptor.toJson`, `RecordDescriptor.toJson`, and
`VariantDescriptor.toJson` export metadata without functions or type casts.
`WireSchema` has `unit`, `boolean`, `string`, `natural`, `integer`, `option`,
`list`, `array`, `product`, `map`, `record`, `variant`, `named`, and `ref`
constructors and `WireSchema.toJson`. A named schema carries a `TypeId`,
version string, and body. `ref` can refer to a separately assembled recursive
graph; there is no graph resolver, completeness checker, or recursive codec
generator in this implementation.

`Presentation α Output` has `render : α → Output`.
`view.contramap (project : β → α) : Presentation β Output` adapts inputs;
`view.map (render : Output → β) : Presentation α β` adapts output.
These are ordinary values, so compact and detailed presentations coexist.
No DOM or form editor interpretation is selected by the ontology.

## Operations, errors, and host interpreters

All names in this section are in `Contract`.

`OperationKind` has `.query` and `.command`.
`OperationId` has `namespaceName`, `name`, and `version`, all strings.
`OperationId.validate` rejects empty components.

`Operation kind Input Output Error` has a private constructor and public
`identity : OperationId`, `inputCodec : Codec Input`,
`outputCodec : Codec Output`, and `errorCodec : Codec Error`.

```lean
Operation.create (kind : OperationKind) (identity : OperationId)
  (input : Codec Input) (output : Codec Output) (error : Codec Error)
  : Validation (Operation kind Input Output Error)
Operation.canonical (kind : OperationKind) (identity : OperationId)
  [Wire Input] [Wire Output] [Wire Error]
  : Validation (Operation kind Input Output Error)
Operation.kind (operation : Operation k Input Output Error) : OperationKind
Operation.describe (operation : Operation k Input Output Error) : OperationInfo
```

`OperationInfo` preserves `identity`, `kind`, and `input`, `output`, `error`
schemas. `OperationInfo.toJson` produces portable metadata. Assembly-time
validation is explicit: compose `Operation.create` calls in a `Validation`
block and supply the successful descriptors to the application.

`CallError DomainError` has these constructors:

```lean
.domain (error : DomainError)
.unauthenticated
.forbidden
.transport (error : TransportError)
.protocol (error : ProtocolError)
.decode (errors : DecodeErrors)
.incompatible (details : ContractMismatch)
.cancelled
```

`TransportError` has `code : String`, `detail : String := ""`.
`ProtocolError` additionally has `status : Option Nat := none` between those
fields. `ContractMismatch` has `expected` and `received : OperationId`.
`CallError.mapDomain (f : ε → δ)` changes only the typed domain payload.

```lean
abbrev CallResult Output Error := Except (CallError Error) Output
abbrev DomainResult Output Error := Except Error Output
abbrev Handler (m : Type → Type) (operation : Operation kind Input Output Error) :=
  Input → m (DomainResult Output Error)

structure Interpreter (m : Type → Type) where
  call : {kind : OperationKind} → {Input Output Error : Type} →
    Operation kind Input Output Error → Input → m (CallResult Output Error)
```

`Interpreter.call` preserves every type index. Prefer ordinary smaller service
records for shared orchestration, such as the `TicketService m` in
[`tests/ontology/Fixtures.lean`](../../tests/ontology/Fixtures.lean).
Its `duplicateTicket` runs unchanged through a direct `Id` dictionary and an
`ExceptT (CallError TicketError) Id` dictionary backed by the wire interpreter.
Native and browser applications can supply different monads and transports.

The shared transport boundary is:

```lean
structure WireRequest where
  operation : OperationId
  kind : OperationKind
  input : WireValue

inductive WireResponse where
  | success (value : WireValue)
  | domainError (value : WireValue)

structure Transport (m : Type → Type) where
  send : WireRequest → m (CallResult WireResponse Empty)

Transport.interpreter [Monad m] (transport : Transport m) : Interpreter m
serve [Monad m] (operation : Operation kind Input Output Error)
  (handler : Handler m operation) (request : WireRequest)
  : m (CallResult WireResponse Empty)
```

The interpreter encodes input, decodes success with the output codec, decodes
declared failures with the error codec, and preserves every transport/protocol
failure. `Empty` means a raw transport cannot manufacture a typed domain error.
`serve` checks identity/version, kind, and input before invoking a typed handler,
then encodes its output or domain error.

For explicit service registration:

```lean
Route.ofHandler [Monad m] (operation : Operation kind Input Output Error)
  (handler : Handler m operation) : Route m
Router.create (routes : List (Route m)) : Validation (Router m)
Router.manifest (router : Router m) : List OperationInfo
Router.transport [Monad m] (router : Router m) : Transport m
```

`Route` has public `info` and `invoke`; `Router` has public `routes`; both have
private constructors. Duplicate exact identities are rejected, including when
two routes claim different kinds for the same identity. Different versions
may coexist. Only registered operations are reachable. An unknown router
operation yields `protocol operation.not_found`; invoking a particular route
with another identity yields `incompatible`. A kind mismatch yields
`protocol operation.kind_mismatch`.

## Adapter and correctness limits

- Lean/Std JSON is the native reference implementation, not a promise that
  this compiler can lower every JSON/TreeMap dependency. P02 defines no JS
  constructor ABI or browser intrinsics; connect these codecs through explicit
  compiler/runtime adapters.
- `Lean.Json.parse` collapses duplicate textual JSON object keys before codec
  validation. Do not claim duplicate-key rejection at the raw JSON text boundary.
  Schema builders reject duplicate field/tag declarations and maps reject
  duplicate decoded keys. Unknown tags/fields and malformed values are tested.
- Only `Nat` and `Int` have built-in integer codecs. Fixed-width integers,
  floats, dates, bytes, and storage-specific keys need explicit checked mappings
  and declared schemas. There is no silent conversion to JS `number`.
- Codecs and descriptor dictionaries are trusted Lean definitions. Optional
  law structures do not automatically certify custom getters, constructors,
  enumerations, checked mappings, or canonical encodings. Manifests are
  descriptions, not proofs or cryptographic compatibility digests.
- `TypeId`, schema versions, and validation contract versions are explicit
  author choices. No global identity registry or automatic migration/contract
  negotiation is present. Scope restrictions and validator semantics are not
  inferred into schema metadata; use distinct declared identities/versions
  when they change a public contract.
- Wire `.key` error paths are distinct from semantic `.field` paths. A form
  adapter must map known wire fields explicitly; an unknown path must remain a
  form-level error. Reflection does not authorize arbitrary mutation.
- Query/command is retained at the type and wire levels, but a query handler
  supplied in an unrestricted monad can still perform effects. The host must
  enforce read capabilities, authorization, transactions, and retry policy.
- No HTTP bindings, status registry, browser `fetch`, native IO adapter,
  cancellation engine, request correlation, caching, revision policy, or
  transaction wrapper is implemented. A host transport maps HTTP success and
  declared domain-error statuses to `WireResponse` and other failures to
  `CallError Empty`. It must also check response correlation and handle its
  actual cancellation capability. Reusing orchestration does not make several
  calls atomic.
- Codec, descriptor, and operation value types are in `Type` (universe zero).
  Paths, lenses, identity, validation, and presentation support the universes
  shown by their Lean declarations.

## Checks and handoff

From the repository root, run:

```sh
bash tests/ontology/check.sh
```

The script creates an isolated temporary `LEAN_PATH`, compiles both libraries
and the fixtures with the pinned `lean`, runs
`lean --run tests/ontology/Main.lean`, and verifies seven intentionally failing
Lean modules. It writes no Lake configuration and installs nothing. Temporary
artifacts and failure diagnostics are retained at the printed path.

Verified outcome on Lean 4.33.0: six executable groups passed (paths/validation,
integers, combinators, references, descriptors, operations) and all seven
compile-time rejections passed (nominal reference, path composition, field
value, operation kind, input, output, and error). Tests include values above
`2^256`, a 201-digit natural, negative big integers, malformed values, nested
options, duplicate map keys, missing/unknown fields, two codecs and presentations
for the same type, structured conflict payloads, and two service interpretations
of shared orchestration. Invalid requests are shown not to invoke handlers.

Source files added by P02:

- `engine/LeanOntology.lean`
- `engine/LeanOntology/Path.lean`, `Validation.lean`, `Identity.lean`, `Schema.lean`,
  `Codec.lean`, `Descriptor.lean`, and this `API.md`
- `engine/LeanContract.lean`, `engine/LeanContract/Operation.lean`, `engine/LeanContract/Transport.lean`
- `tests/ontology/Fixtures.lean`, `Main.lean`, `check.sh`, `RejectReference.lean`,
  `RejectPath.lean`, `RejectFieldValue.lean`, `RejectOperationKind.lean`,
  `RejectOperationInput.lean`, `RejectOperationOutput.lean`, `RejectOperationError.lean`

No root configuration or sibling sources were manually edited. The initial
`lake env lean --version` check automatically created `lake-manifest.json`
(Lake reported no prior manifest); it was left in place for the integrating
worker. No commits, network calls, dependency installs, or subagents were used.
