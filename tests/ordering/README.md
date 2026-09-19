# FS01 ordering domain

Run the focused gate from the repository root:

```sh
bash tests/ordering/check.sh
```

Uses the root `Ordering` Lake library and cached LeanJS; there is no nested package
or sibling dependency. Generated modules, declarations, metadata, native JSON,
fixture oleans, and negative-test logs go in `tests/ordering/.build/`. Lake writes
the domain build to `.lake/`. The script does not install anything or run other
suites. The parent owns ignore rules for these generated paths.

## Public API

- `Currency`, `Money currency`, `Money.add`, `Money.scale`: arbitrary-precision,
  nonnegative minor units; addition and scaling preserve currency. No floating
  point, implicit conversion, or rounding. `Money.scale_one` proves the unit law.
- `Configuration`, finite `Temperature`/`Size`/`Milk`/`Shots`, `Configuration.all`,
  `Configuration.admissible`, `Configuration.check`: 180 configurations, 125
  admissible. Checked `AdmissibleConfiguration` carries a proof of admissibility.
- `Choice`, `Pattern`, `PricingRule currency`, `PricingRule.evaluate`, `preview`:
  stored first-order pricing data interpreted purely. All matching exact signed
  adjustments apply; the first matching override replaces the adjusted price.
  Negative totals return `PricingError.negativeTotal`, without clamping.
- `Stock.empty`, `Stock.fromRaw`, `Stock.reserve`, `Stock.release`: checked stock
  reconstruction and updates. Every `Stock` carries `reserved ≤ capacity`.
  Zero reserve/release and over-release are errors. Constructors are private.
- `OfferId`, `QuoteId`, `OrderId` are distinct nominal types. `Offer currency`
  holds the display label, offer/rule revisions, rule, and quote lifetime.
- `Quote` / `QuoteError`, `PlaceOrder` / `PlaceOrderError`, `CancelOrder` /
  `CancelOrderError` are explicit command inputs and typed rejection channels.
  `Quoted currency` retains the admissible choice, positive quantity, exact
  unit/total money (with a multiplication proof), label, revisions, and times.
- `Order currency stage`, `Placement`, `Receipt`, `Order.pay`, `Order.cancel`
  model placed, paid, and cancelled states with required payloads. Payment
  verifies amount, reference, and time. Cancellation verifies reason and time.
  `StoredOrder` permits heterogeneous state storage without erasing payloads.
- `Memory.empty`, `Memory.quote`, `Memory.placeOrder`, `Memory.cancelOrder`,
  `Memory.confirmPayment`, `Memory.changeRule`, `Memory.changeOffer`: pure,
  deterministic single-offer interpreter, returning a new snapshot only on
  success. Rule/offer edits advance their respective revisions. `now` is an
  explicit natural-number clock tick; IDs start at 1 and advance on success.

## Quote and inventory policy

Quotes do not reserve stock. Placement accepts a retained quote by ID, checks
both revisions and the half-open validity interval `[issuedAt, expiresAt)`, and
reserves capacity. It never evaluates a new price or trusts a submitted price.
Changed or expired quotes return distinct typed errors; a fresh quote is needed.
Used quotes stay used after cancellation. Cancellation releases the reservation
exactly once; paid orders cannot be cancelled and retain their capacity. This
sample has no fulfillment/refund operation. Stock is shared by all configurations
of the one offer. Private `Memory` construction protects the quote/order book
and its reservation history from ordinary Lean callers.

## Reference adaptations and portability

Read-only source reference: LeanDB's [`examples/eats/Eats/Config.lean`](https://github.com/theoriclabs/LeanDB/blob/v0.4.0/examples/eats/Eats/Config.lean) (fetched under `adapters/native/.lake/packages/leandb` by a native build).
The drink choices, two admissibility restrictions, option patterns, and pricing
shape are adapted into ordinary Lean declarations. No LeanDB enum deriving,
codecs, entities, catalog tables, or maintained summary fields are copied.
Adjustments use exact `Int` instead of `Int64`. Override order is an explicit
policy, rather than Eats' disjointness lint. Negative-price rejection occurs in
the evaluator for each requested configuration, rather than silently clamping.

The initial `Probe.lean` exposed an unsupported dependency:
`Pattern.matches → Array.all → Array.allM → Array.anyM` (`implemented_by`).
`Pattern` now uses semantically equivalent pure `List.all`. All final exports
compile through existing LeanJS without intrinsics or engine changes. Other
arrays remain supported, including enumeration, pricing folds, and find/filter.
`GenerateDomain.lean` follows the existing generator pattern and exports real
domain commands as well as parameterized behavior fixtures.

LeanJS uses the existing `leanjs-v0` ABI and exact BigInt representation. Lean
proofs are erased; generated JavaScript objects are not an untrusted-input
validation boundary. Future adapters must decode inputs and use the authoritative
interpreter. Persistence, wire codecs, authentication, transactions, concurrent
inventory isolation, durable IDs, and payment-provider effects belong to later
work packages. This fixture makes no claims about those layers.

## Checks

`check.sh` runs the root library build, positive Lean type/proof checks, native
behavior assertions, generated JavaScript assertions, output parity, and nine
compile-failure fixtures. Failure fixtures must produce the intended diagnostic;
an import or unrelated elaboration error does not count as passing.

Parity covers 35 result vectors: 25 order scenarios (five exact amounts × five
Unicode/escaped labels), five pricing enumerations over the whole finite space,
and five stock scenarios. Amounts include zero, `2^53 + 1`, `2^63`, and
`123456789012345678901234567890`. JavaScript also checks independent expected
totals instead of accepting agreement alone.

Assertions cover successful quote/place/cancel/replacement/payment, fresh quotes
after revisions change, bad configurations/prices, missing identities, zero
quantity/lifetime, future/expired quotes, both stale revisions, duplicate use,
last-unit contention represented as sequential decisions, empty reasons,
backdated transitions, duplicate cancellation/payment, payment mismatch,
cancelled/paid transition rejection, capacity reconstruction/overflow/release,
deterministic IDs, and immutable snapshots.

Negative fixtures reject currency mixing, paying a cancelled order, composing a
second payment after payment, direct stock/configuration/quote/memory constructors,
and stock/configuration record updates that bypass invariant checks. No `sorry`
or custom axioms are used. This is the FS01 gate only, not full-plan completion.
