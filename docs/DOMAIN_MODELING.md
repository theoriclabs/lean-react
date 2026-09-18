# Model the domain in Lean

[Documentation](README.md) · [Get started](GETTING_STARTED.md) · [Architecture](ARCHITECTURE.md)

A useful domain model tells callers what a value means and which operations make sense for it. Lean lets you express that with ordinary algebraic data types, or with dependent indices and proofs when the distinction needs stronger enforcement. You do not need a theorem about every form field.

The examples below use the existing ordering domain. They are complete Lean snippets: save one as a `.lean` file and run `lake env lean path/to/file.lean` from this checkout after `lake build Ordering Cafe`. `npm run test:docs` checks the marked examples automatically.

## Keep meanings distinct

`Money currency` records a nonnegative count of minor units. The currency parameter means addition requires matching currencies.

<!-- lean-check: domain-money -->
```lean
import Ordering.Domain.Values
open Ordering

def coffee : Money .usd := ⟨450⟩
def oat : Money .usd := ⟨75⟩

#guard (coffee.add oat).minor == 525
#guard (coffee.scale 3).minor == 1350

example (amount : Money .usd) : amount.scale 1 = amount :=
  Money.scale_one amount
```

The parameter establishes which additions are legal. It does not establish a currency conversion rate, the right tax policy or the correct price for a product. Those need their own definitions. The cents representation is exact in native Lean and becomes `bigint` in generated JavaScript.

This example is intentionally rejected:

```lean
import Ordering.Domain.Values
open Ordering

def invalid (usd : Money .usd) (eur : Money .eur) : Money .usd :=
  usd.add eur
```

The second argument has type `Money Currency.eur` where `Money Currency.usd` is required. The existing [currency rejection fixture](../tests/ordering/negative/WrongCurrency.lean) tests this boundary; it must fail for the intended type error, not for a missing import.

`Money` belongs to this example's domain, not a mandatory framework hierarchy. An application can define different monetary policies or avoid money entirely.

## Reconstruct valid values at boundaries

A value read from JSON or a database does not become trustworthy because the application uses Lean. Check the raw representation before constructing the domain value.

The stock model carries a proof that its reserved quantity fits its capacity. A checked constructor either produces such a value or returns an explicit error:

<!-- lean-check: domain-stock -->
```lean
import Ordering.Domain.Values
open Ordering

#guard match Stock.fromRaw 10 11 with
  | .error .invalidCapacity => true
  | _ => false

#guard match (Stock.empty 10).reserve 3 with
  | .ok stock => stock.reserved == 3
  | .error _ => false

example (stock : Stock) : stock.reserved ≤ stock.capacity :=
  Stock.reserved_le_capacity stock
```

The constructor is private. Ordinary callers use `Stock.empty`, `Stock.fromRaw`, `reserve` and `release`; each successful update establishes the invariant. Invalid external data remains an ordinary runtime error. The proof describes every successfully constructed `Stock`, including values created from previously unknown input.

That bound alone does not prove concurrent inventory correctness. A server must read and update the relevant records within an appropriate transaction. The pure model states the rule; the adapter provides the consistency boundary.

## Let states determine available operations

The [order model](../examples/ordering/Ordering/Domain/Orders.lean) uses `Order currency stage`. A placed order contains placement data, a paid order includes a receipt, and a cancelled order includes cancellation details. Payment consumes a placed order and returns a paid order or a typed error.

This puts workflow requirements in the function's input type. A function accepting a cancelled order cannot pass it to `Order.pay` without first changing the model. Rejection tests cover [the wrong state](../tests/ordering/negative/WrongState.lean) and [a second payment](../tests/ordering/negative/WrongComposition.lean).

Persisted state still requires checked reconstruction. An index in a Lean type does not make a corrupt row valid, and a payment transition does not prove that an external payment provider actually charged a card. The café does not take payments.

## Share behavior across execution targets

`Cafe.rule` is data interpreted by a pure Lean pricing function. The same source runs in the native save handler and compiles to JavaScript for interactive previews:

<!-- lean-check: domain-cafe -->
```lean
import Cafe

#guard Cafe.preview "hot" "regular" "whole" "double" false == "ok:450"
#guard Cafe.preview "iced" "large" "oat" "double" false == "ok:650"
#guard Cafe.preview "iced" "small" "oat" "double" false == "error:small_iced"
#guard Cafe.preview "hot" "regular" "whole" "triple" true == "error:decaf_triple"
```

The underlying ordering model has typed configuration/pricing errors. The café maps them to stable error codes for its small browser entry point. Its [JavaScript bridge](../examples/cafe/domain.mjs) converts representations; it does not reimplement pricing or availability.

The UI evaluates a proposed change against the current draft. If the Lean model rejects that candidate, the corresponding choice is disabled with an explanation. The native API reconstructs and evaluates a submitted draft again before saving. Disabling a button is a usability feature, not authorization.

Only LeanJS's supported subset compiles for browser execution. Native IO, arbitrary FFI and unsupported compiler constructs need explicit host boundaries. Use [ABI documentation](../engine/LeanJS/ABI.md) when writing a JavaScript adapter: Lean constructors, wire JSON and database rows are different representations.

## Carry authorization into a read

The ordinary path is a declared rule. [`LeanApp.Policy`](../engine/LeanApp/Policy.lean) supplies `authenticated`, `requireRole minimum roleOf`, `requireAtLeast` / `AtLeast` (evidence the handler cannot invent), `BindingE`, `both`, `either`, `deny` and `withInput`; an application writes `roleOf` once (it may read the resource through the capability) and each binding states its minimum with `{ Policy.requireRole .editor roleOf with … }` or `BindingE.atLeast .editor roleOf …`. The rule's description is published as `metadata.describePolicy` in the manifest, and [`LeanApp.Testing`](../engine/LeanApp/Testing.lean) runs an exhaustive (operation × caller) matrix against the application's own transport so a removed check fails a test rather than shipping; the [Tickets native example](../examples/native/NativeTickets/Registration.lean) and the [application fixture](../tests/app/AclFixture.lean) show both. A missing role can answer `forbidden` (the default, hiding existence) or the handler's typed `notFound` (uniform responses); choose one per application. Applications that carry a resource in the evidence (an `Access min`) wrap `AtLeast` in their own private structure.

The proof-carrying path is the [Private Notes example](PRIVATE_NOTES.md), which carries a checked grant from authenticated request assembly into a typed database read. Its pure model proves authorized row provenance, exact scoped selection and response noninterference across list, lookup, search, count and export. Removing the owner or tenant check breaks the executable predicate's proof against a separate policy definition.

The native integration resolves session facts and reads SQLite within one transaction, checks decoded row ownership, then uses Lean's shared response semantics. HTTP/browser tests qualify this path; the database, authentication-to-model mapping and native compiler remain trusted. The [guide](PRIVATE_NOTES.md#the-honest-boundary) explains the exact proof boundary and shows what happens when an agent submits an unsafe patch. The [earlier walkthrough](AUTHORIZATION_DEMO.md) retains the broader design, including work not implemented in this slice.

## Build an application around the model

Keep domain definitions free of React, database handles and HTTP requests. Then define the public operation's input, output, error and query/command kind in LeanContract. A LeanApp binding attaches a required access policy, a handler and an explicit HTTP path. Only approved exports enter the application manifest.

The host supplies typed read/write interpreters. It authenticates the request before issuing its context and owns the connection/transaction lifecycle. A generic query handler receives a read capability; that interface has no write field. Trusted native code can still perform IO, so this is API discipline rather than an arbitrary-code sandbox.

Read the [small in-memory application fixture](../tests/app/Main.lean) for the assembly API, then [the café's native adapter](../adapters/native/LeanAppNative/Cafe.lean) for real auth and SQLite. The fixture deliberately uses a local policy; copying it does not create production authentication.

Test both the domain and its interpretations. The ordering suite checks proofs and expected compiler rejections; café tests compare all 180 native/browser configurations against independent expected prices. HTTP and browser tests check the boundaries those pure tests cannot cover. See [check and debug your work](HOW_TO.md#check-and-debug-your-work) for the commands.
