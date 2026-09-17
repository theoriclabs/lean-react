# Why your checkout has 12,288 states and only 888 of them are real

This is for someone who builds frontends, is comfortable with TypeScript, and has heard the phrase "dependent types" without ever needing one. It works through a single example, a checkout form, and shows what the types buy you in practice. The snippets in the body are excerpts from the complete file at the end, which `npm run test:docs` recompiles; the counts come from Lean running the enumeration, not from arithmetic done by hand.

## The checkout

A checkout page with the usual moving parts:

| Field | Options |
| --- | --- |
| Shipping country | US, Canada, EU, other |
| Shipping method | standard, express, overnight, pickup |
| Payment | card, PayPal, Apple Pay, cash on delivery |
| Card details | present or not |
| Billing same as shipping | yes / no |
| Billing address | present or not |
| Promo code | none, applied, invalid |
| Gift wrap | yes / no |
| Submission | idle, submitting, failed, done |

And the business rules, the kind that arrive one at a time over a year of tickets:

1. Overnight is US only. Pickup is US and Canada. "Other" countries get standard shipping only.
2. Cash on delivery is only for pickup orders.
3. Card details exist if and only if the payment method is card.
4. A separate billing address exists if and only if paying by card and "same as shipping" is off. Otherwise the toggle is meaningless.
5. No gift wrap on pickup orders.

None of these is exotic. Every one of them is a bug someone has shipped.

## How this gets stored in React

Honestly, like this:

```ts
const [country, setCountry] = useState<Country>("us");
const [method, setMethod] = useState<Method>("standard");
const [payment, setPayment] = useState<Payment>("card");
const [card, setCard] = useState<CardDetails | null>(null);
const [billingSame, setBillingSame] = useState(true);
const [billingAddress, setBillingAddress] = useState<Address | null>(null);
const [promo, setPromo] = useState<Promo>({ kind: "none" });
const [giftWrap, setGiftWrap] = useState(false);
const [submission, setSubmission] = useState<Submission>({ kind: "idle" });
```

Nine independent slots. Multiply the options: \(4 \times 4 \times 4 \times 2 \times 2 \times 2 \times 3 \times 2 \times 4 = 12{,}288\) distinct states this store can be in.

Now count the states the five rules actually allow. Ten of the sixteen country/method pairs are legal. For a pickup pair, payment has five shapes (card with either billing option, PayPal, Apple Pay, COD) and gift wrap is forced off; for a non-pickup pair, four payment shapes and two gift wrap options. That gives \(2 \times 5 + 8 \times 8 = 74\) shipping-and-payment shapes, times 3 promo states, times 4 submission states: **888**.

So 7.2% of the states your store can represent are valid. The other 11,400 are each a specific bug: COD selected with express shipping, a billing address hanging around after switching to PayPal, gift wrap charged on a pickup order, overnight offered to a customer in Lisbon.

You know this. It's why the submit handler has a wall of `if` statements, why `disabled={...}` expressions get long, and why the same rule is written three times: once in the option list, once in validation, once in the API client. When product adds a sixth rule, you find the places by grep.

The technical name for this is **state explosion**, and the cause is precise: independent slots multiply. Every field you add multiplies the representable states by its option count, while the valid states grow much more slowly because the rules cut them down. The gap between the two numbers is where bugs live.

## Types are sets; the shape decides the count

Think of a type as the set of values it allows.

- A **product** (a record, an object, a tuple) allows every combination: `A × B` has \(|A| \cdot |B|\) values. Nine `useState` slots are one big product.
- A **sum** (a tagged union, `A | B` with a discriminant) allows one alternative at a time: \(|A| + |B|\).

That's the whole trick. State explosion is what you get when you use a product where the domain is a sum. Rule 3 says card details exist exactly when payment is card. As a product, that's `payment × (card | null)`: 4 × 2 = 8 combinations, of which 4 are meaningful. As a sum, it's:

```ts
type Payment =
  | { kind: "card"; details: CardDetails; billing: Billing }
  | { kind: "paypal" }
  | { kind: "applePay" }
  | { kind: "cod" };
```

Now there is no state where card details exist without card payment. TypeScript can do this, and you may already do it. Rules 3 and 4 fold into this union. Rule 2, though, says something a plain union can't: **which alternatives exist depends on a different field.** COD is an option only when shipping is pickup. In TypeScript you write a guard for that and hope every caller remembers.

Rule 1 has the same shape. Which methods exist depends on the country. Rule 5: which gift wrap values exist depends on the method.

That's the pattern. Three of the five rules say "the set of valid values for this field depends on the value of another field." A type system that can express that sentence is what "dependent types" means. Nothing more mystical than that.

## Building the type in Lean

Start with the plain enums. These are exactly TypeScript string unions:

```lean
inductive Country where
  | us | ca | eu | other
  deriving Repr, BEq, DecidableEq

inductive Method where
  | standard | express | overnight | pickup
  deriving Repr, BEq, DecidableEq
```

### Rule 1: a field that carries evidence

Rule 1 is a relation between two fields. Write it as an ordinary function, the same one you'd write in TypeScript:

```lean
def Method.allowed : Country → Method → Bool
  | .us, _ => true
  | .ca, .overnight => false
  | .ca, _ => true
  | .eu, .standard | .eu, .express => true
  | .eu, _ => false
  | .other, .standard => true
  | .other, _ => false
```

Now the part with no TypeScript equivalent. Put the *result of that check* into the record as a field:

```lean
structure Shipping where
  private mk ::
  country : Country
  method : Method
  ok : Method.allowed country method = true
```

Read `ok`'s type as a sentence: "`Method.allowed country method` equals `true`." A value of that type is evidence that the sentence holds. You can't fabricate one. The only way to get one is to actually run the check:

```lean
def Shipping.check (country : Country) (method : Method) : Option Shipping :=
  if h : Method.allowed country method = true then some ⟨country, method, h⟩ else none
```

The `if h : ...` form is the whole mechanism. It's an ordinary `if` on a boolean, except that inside the `then` branch, `h` is a value you can store. It's the check's result promoted from "a boolean that was true a moment ago" to "a fact the compiler will trust from now on."

`private mk` closes the other door: no one outside this module can build a `Shipping` by hand. Everyone goes through `check`.

Count: `Country × Method` has 16 values. `Shipping` has 10. The type has exactly as many inhabitants as there are legal shipping choices.

### Rule 2: a type that depends on a value

COD exists only for pickup. So `Payment` isn't one type. It's four types, one per shipping method, and they're almost the same:

```lean
inductive Payment : Method → Type where
  | card (details : CardDetails) (billing : Billing) : Payment m
  | paypal : Payment m
  | applePay : Payment m
  | cod : Payment .pickup
```

`Payment : Method → Type` says: give me a method, I'll give you a type. `Payment .standard` has three alternatives. `Payment .pickup` has four. `cod`'s signature ends in `Payment .pickup` and nothing else, so you cannot construct a `cod` value at any other type.

That's a dependent type. A type indexed by a value. In TypeScript terms, imagine `Payment<M extends Method>` where the union members available actually change with `M`, and the compiler enforces it at construction and at every match.

### Rule 5: the same trick as rule 1

Gift wrap is forbidden on pickup. Write the constraint as a field whose type is the sentence:

```lean
structure Checkout where
  shipping : Shipping
  payment : Payment shipping.method
  giftWrap : Bool
  noWrapForPickup : shipping.method = .pickup → giftWrap = false
  promo : Promo
  submission : Submission
```

Two things to notice. `payment : Payment shipping.method` ties the payment field's *type* to the shipping field's *value*. That is rule 2, stated as a field declaration. And `noWrapForPickup` is an implication: "if the method is pickup, then gift wrap is false." When the method isn't pickup, the implication is trivially satisfied and both gift wrap values are allowed.

### The one door

The form itself is still flat. The user can click COD and then switch to express; the UI has to hold that. So there is a flat `Draft` type with nine independent fields, and one function that turns it into a `Checkout` or an error:

```lean
def Draft.check (d : Draft) : Except CheckoutError Checkout := do
  let some shipping := Shipping.check d.country d.method
    | throw (.methodNotAvailable d.country d.method)
  let payment : Payment shipping.method ← match d.payment with
    | .paypal => pure .paypal
    | .applePay => pure .applePay
    | .card =>
      let some details := d.card | throw .cardDetailsRequired
      if d.billingSame then pure (.card details .sameAsShipping)
      else
        let some address := d.billingAddress | throw .billingAddressRequired
        pure (.card details (.separate address))
    | .cod =>
      if h : shipping.method = .pickup then pure (h ▸ Payment.cod)
      else throw .codRequiresPickup
  if hp : shipping.method = .pickup then
    match d.giftWrap with
    | true => throw .noGiftWrapForPickup
    | false => pure { shipping, payment, giftWrap := false, noWrapForPickup := fun _ => rfl,
                      promo := d.promo, submission := d.submission }
  else
    pure { shipping, payment, giftWrap := d.giftWrap, noWrapForPickup := fun h => absurd h hp,
           promo := d.promo, submission := d.submission }
```

This is the validation function you would have written anyway. The difference is what comes out the other end. In TypeScript, a successful validation returns the same flat object you put in, and every downstream function has to trust that validation happened. Here it returns a `Checkout`, and a `Checkout` cannot exist unless every rule held.

The `h ▸ Payment.cod` line is the only new syntax: "use the fact `h` (that the method is pickup) to let a `Payment .pickup` be used where a `Payment shipping.method` is expected." The compiler checks that `h` says exactly that.

## Lean counts it

Rather than trust the arithmetic, enumerate. Fix payloads to one sample value each (so we count shapes, not strings) and build every `Checkout`:

```lean
def Checkout.all : List Checkout :=
  Shipping.all.flatMap fun shipping =>
    (Payment.shapes shipping.method).flatMap fun payment =>
      (giftWrapOptions shipping).flatMap fun ⟨giftWrap, noWrap⟩ =>
        Promo.shapes.flatMap fun promo =>
          Submission.shapes.map fun submission =>
            { shipping, payment, giftWrap, noWrapForPickup := noWrap, promo, submission }

#eval Shipping.all.length   -- 10
#eval Checkout.all.length   -- 888
#eval Flat.all.length       -- 12288
```

`Flat` is the nine-independent-fields record, the React store. Lean prints `10`, `888`, `12288`. The `Checkout` type has 888 inhabitants. The valid-state count and the type's size are the same number, because the type *is* the set of valid states.

You cannot write the enumeration wrong in an interesting way. Try to add `.cod` to the non-pickup payment shapes and it won't typecheck. Try to add `⟨true, ...⟩` to the pickup gift wrap options and you'll be asked to prove `true = false`.

## What this changes day to day

**Downstream code has no guards.** Once a function takes a `Checkout`, rules 1 through 5 are facts. The API client that serializes the order doesn't check whether COD is allowed. The order summary doesn't check whether a billing address should exist. The label function matches `.cod` and knows the method is pickup:

```lean
def Payment.label : Payment m → String
  | .card details _ => "Card ending " ++ details.last4
  | .paypal => "PayPal"
  | .applePay => "Apple Pay"
  | .cod => "Cash on pickup"
```

**The rule is written once and used twice.** `Method.allowed` builds the proof in `Shipping.check`. The same function drives the UI:

```lean
def Method.available (country : Country) : List Method :=
  Method.all.filter (Method.allowed country)
```

Disable the buttons that aren't in `available`. The validator and the `disabled` expression cannot disagree, because they are the same function.

**Adding a rule is a guided refactor.** Add a sixth constraint as a field on `Checkout`, and `Draft.check` stops compiling until you produce the evidence. Add a fifth country, and `Method.allowed` stops compiling until you say what it allows. Nothing to grep for.

**The proofs cost nothing at runtime.** This model compiles through LeanReact's compiler to JavaScript. In the generated TypeScript declarations, `Shipping.mk` is a constructor over `[Country, Method, null]`; the `ok` field is erased to `null`. `Checkout.mk` has `null` where `noWrapForPickup` was. The evidence exists at compile time and disappears in the bundle. Running the compiled `Draft.check` in Node:

```
checkCodExpress    = error:cod_requires_pickup
checkCodPickup     = ok:Cash on pickup
checkWrapPickup    = error:no_gift_wrap_for_pickup
checkOvernightEu   = error:method_not_available
checkCardNoDetails = error:card_details_required
checkCardOk        = ok:Card ending 4242
validCount         = 888n
```

The last line is the same enumeration run as a loop in the browser runtime.

## What it does not change

**The form is still flat.** Users make invalid intermediate choices, so the draft has to hold them. What changes is that the flat shape stops at `Draft.check`. Everything after that door works on the 888, not the 12,288.

**Invalid combinations still need UI.** The type tells you COD-with-express can't reach the API. It doesn't tell you whether to hide the COD button, disable it, or show an error after the fact. `Method.available` gives you the predicate; the design is yours.

**The rules can be wrong.** `Method.allowed` could say Canada gets overnight. The compiler checks that your code is consistent with the rules you wrote, not that the rules match the business.

**Payloads aren't counted.** The 888 counts shapes. Card numbers, addresses, and promo strings are infinite, and their validity (is this a real postal code?) is a separate parsing concern.

**Some Lean doesn't reach the browser.** The compiler supports a documented subset. `reprStr` on an error still pulls in `Std.Format.pretty`, which is not portable, so errors get an explicit `code` function (the better wire API anyway). `List.length` / `foldl` / `map` / `flatMap` are now iterative host builtins; a 12,000-element list is in the compiler suite. User-written recursive List functions and `List.range` still use the JavaScript stack. The indexed `Payment` family and the `▸` cast compiled without issue.

## The four ideas, in frontend terms

| Lean construct | What it is | TypeScript analogue |
| --- | --- | --- |
| `inductive` with payloads | A tagged union where each case carries only its own data | Discriminated union. Same power. |
| `structure` with a `Prop` field | A record that carries evidence a check passed; constructible only by running the check | None. Closest is a branded type, which is a promise, not a proof. |
| `inductive T : Index → Type` | A family of related types, one per index value; which constructors exist depends on the index | None. Generics can't remove union members based on a runtime value. |
| `field : Expr(otherField)` | A field whose type mentions another field's value | None. This is the dependent part. |

The second row is the one to internalize first. `if h : check then ⟨value, h⟩` is the entire on-ramp: run your existing boolean check, keep the result as a field, close the constructor. Everything downstream gets to assume the check passed, and the compiler enforces that assumption. The dependent family in row three is how you say "these options exist only over there." Rows two and three together are what took a 12,288-state store down to a type with 888 values.

## Try it

Save the listing below as `Checkout.lean` anywhere inside a LeanReact checkout and run:

```sh
lake env lean Checkout.lean
```

It prints `10`, `888`, `12288`, `2`. To compile it to JavaScript, add `import LeanJS` at the top and a `run_meta` block calling `LeanJS.writeModule` with the declarations you want exported; the [how-to guide](../HOW_TO.md#compile-the-lean-definitions) shows the pattern.

## Complete listing

<!-- lean-check: checkout-state-explosion -->
```lean
namespace Checkout

inductive Country where
  | us | ca | eu | other
  deriving Repr, BEq, DecidableEq

inductive Method where
  | standard | express | overnight | pickup
  deriving Repr, BEq, DecidableEq

def Method.allowed : Country → Method → Bool
  | .us, _ => true
  | .ca, .overnight => false
  | .ca, _ => true
  | .eu, .standard | .eu, .express => true
  | .eu, _ => false
  | .other, .standard => true
  | .other, _ => false

structure Shipping where
  private mk ::
  country : Country
  method : Method
  ok : Method.allowed country method = true

def Shipping.check (country : Country) (method : Method) : Option Shipping :=
  if h : Method.allowed country method = true then some ⟨country, method, h⟩ else none

structure CardDetails where
  last4 : String
  expiry : String
  deriving Repr

structure Address where
  line1 : String
  postalCode : String
  deriving Repr

inductive Billing where
  | sameAsShipping
  | separate (address : Address)

inductive Payment : Method → Type where
  | card (details : CardDetails) (billing : Billing) : Payment m
  | paypal : Payment m
  | applePay : Payment m
  | cod : Payment .pickup

inductive Promo where
  | none
  | applied (code : String) (discountMinor : Nat)
  | invalid (code : String)

inductive Submission where
  | idle
  | submitting
  | failed (message : String)
  | done (orderId : Nat)

structure Checkout where
  shipping : Shipping
  payment : Payment shipping.method
  giftWrap : Bool
  noWrapForPickup : shipping.method = .pickup → giftWrap = false
  promo : Promo
  submission : Submission

/-! ## The one door: a flat draft becomes a Checkout or an error. -/

inductive PaymentKind where
  | card | paypal | applePay | cod
  deriving Repr, BEq, DecidableEq

structure Draft where
  country : Country
  method : Method
  payment : PaymentKind
  card : Option CardDetails
  billingSame : Bool
  billingAddress : Option Address
  giftWrap : Bool
  promo : Promo
  submission : Submission

inductive CheckoutError where
  | methodNotAvailable (country : Country) (method : Method)
  | codRequiresPickup
  | cardDetailsRequired
  | billingAddressRequired
  | noGiftWrapForPickup
  deriving Repr

/-- Stable codes for the UI and the wire; no `Repr` machinery in the browser. -/
def CheckoutError.code : CheckoutError → String
  | .methodNotAvailable _ _ => "method_not_available"
  | .codRequiresPickup => "cod_requires_pickup"
  | .cardDetailsRequired => "card_details_required"
  | .billingAddressRequired => "billing_address_required"
  | .noGiftWrapForPickup => "no_gift_wrap_for_pickup"

def Draft.check (d : Draft) : Except CheckoutError Checkout := do
  let some shipping := Shipping.check d.country d.method
    | throw (.methodNotAvailable d.country d.method)
  let payment : Payment shipping.method ← match d.payment with
    | .paypal => pure .paypal
    | .applePay => pure .applePay
    | .card =>
      let some details := d.card | throw .cardDetailsRequired
      if d.billingSame then pure (.card details .sameAsShipping)
      else
        let some address := d.billingAddress | throw .billingAddressRequired
        pure (.card details (.separate address))
    | .cod =>
      if h : shipping.method = .pickup then pure (h ▸ Payment.cod)
      else throw .codRequiresPickup
  if hp : shipping.method = .pickup then
    match d.giftWrap with
    | true => throw .noGiftWrapForPickup
    | false => pure { shipping, payment, giftWrap := false, noWrapForPickup := fun _ => rfl,
                      promo := d.promo, submission := d.submission }
  else
    pure { shipping, payment, giftWrap := d.giftWrap, noWrapForPickup := fun h => absurd h hp,
           promo := d.promo, submission := d.submission }

/-! ## Let Lean count. Payloads are fixed to one sample so we count shapes, not strings. -/

def sampleCard : CardDetails := ⟨"4242", "12/29"⟩
def sampleAddress : Address := ⟨"1 Main St", "94105"⟩

def Country.all : List Country := [.us, .ca, .eu, .other]
def Method.all : List Method := [.standard, .express, .overnight, .pickup]
def PaymentKind.all : List PaymentKind := [.card, .paypal, .applePay, .cod]
def Promo.shapes : List Promo := [.none, .applied "SAVE10" 1000, .invalid "NOPE"]
def Submission.shapes : List Submission := [.idle, .submitting, .failed "declined", .done 1]

def Shipping.all : List Shipping :=
  Country.all.flatMap fun country => Method.all.filterMap fun method => Shipping.check country method

def Payment.common (m : Method) : List (Payment m) :=
  [.card sampleCard .sameAsShipping, .card sampleCard (.separate sampleAddress), .paypal, .applePay]

def Payment.shapes : (m : Method) → List (Payment m)
  | .pickup => Payment.common .pickup ++ [.cod]
  | m => Payment.common m

def giftWrapOptions (s : Shipping) : List { g : Bool // s.method = .pickup → g = false } :=
  if h : s.method = .pickup then [⟨false, fun _ => rfl⟩]
  else [⟨false, fun _ => rfl⟩, ⟨true, fun hp => absurd hp h⟩]

def Checkout.all : List Checkout :=
  Shipping.all.flatMap fun shipping =>
    (Payment.shapes shipping.method).flatMap fun payment =>
      (giftWrapOptions shipping).flatMap fun ⟨giftWrap, noWrap⟩ =>
        Promo.shapes.flatMap fun promo =>
          Submission.shapes.map fun submission =>
            { shipping, payment, giftWrap, noWrapForPickup := noWrap, promo, submission }

/-- What a flat React store admits: every field independent. -/
structure Flat where
  country : Country
  method : Method
  payment : PaymentKind
  hasCard : Bool
  billingSame : Bool
  hasBillingAddress : Bool
  promo : Promo
  giftWrap : Bool
  submission : Submission

def Bool.all : List Bool := [false, true]

def Flat.all : List Flat :=
  Country.all.flatMap fun country => Method.all.flatMap fun method =>
    PaymentKind.all.flatMap fun payment => Bool.all.flatMap fun hasCard =>
      Bool.all.flatMap fun billingSame => Bool.all.flatMap fun hasBillingAddress =>
        Promo.shapes.flatMap fun promo => Bool.all.flatMap fun giftWrap =>
          Submission.shapes.map fun submission =>
            { country, method, payment, hasCard, billingSame, hasBillingAddress, promo, giftWrap, submission }

#eval Shipping.all.length   -- 10 of 16 (country, method) pairs
#eval Checkout.all.length   -- 888
#eval Flat.all.length       -- 12288

/-! ## The rules that were checked once are now facts every caller can use. -/

/-- No guard needed: a `.cod` value can only exist when the method is pickup. -/
def Payment.label : Payment m → String
  | .card details _ => "Card ending " ++ details.last4
  | .paypal => "PayPal"
  | .applePay => "Apple Pay"
  | .cod => "Cash on pickup"

def Checkout.paymentLabel (c : Checkout) : String := c.payment.label

/-- Same predicate the checker used: drives `disabled` in the UI. -/
def Method.available (country : Country) : List Method :=
  Method.all.filter (Method.allowed country)

#eval (Method.available .eu).length  -- 2

end Checkout
```
