# You changed the order. Why is checkout showing the old price?

You have two mugs in your cart. They cost $12 each. Delivery costs $5, so the total is $29.

Then you notice the shop is nearby. You switch to pickup.

The address field disappears. The total should become $24. While the new quote loads, the old delivery request finishes. Its callback puts $29 back on the screen. The Pay button lights up.

Every value looks reasonable by itself. Two mugs is a valid cart. Pickup is a valid choice. $29 was a valid quote. They just do not belong together.

This is the problem our example should start with. A frontend developer already knows the work involved: clear dependent fields, invalidate cached results, update the button, and guard late callbacks. Add coupons, currencies, and delivery slots, and there are more relationships to keep straight.

Lean lets us put some of those relationships into the types. The compiler can then check that our updates preserve them.

**First, give each choice the data it needs.**

Pickup needs a store. Delivery needs an address and a shipping speed.

```lean
structure Pickup where
  store : String

structure Delivery where
  address : String
  speed : Speed

abbrev Input := Items × (Pickup ⊕ Delivery)
```

Read the last line as “items AND either pickup OR delivery.” The `×` means both. The `⊕` means either.

A configured pickup order has no delivery speed to accidentally charge for. If the form remembers an old address so the user can switch back, that belongs in its draft. It is not part of the selected pickup order.

An ordinary `inductive` with named `pickup` and `delivery` constructors expresses the same choice. The generic `⊕` form is useful below because we can write reusable behavior for any pair of alternatives.

This is also available through TypeScript discriminated unions. It makes a good first step because readers can recognize the pattern before meeting something new.

**Next, distinguish a quote from a quote for this request.**

```lean
structure Request (α : Type) where
  input : α
  generation : Nat
  deriving DecidableEq

structure Quote {α : Type} [Priced α] (request : Request α) where
  amount : Nat
  correct : amount = price request.input
```

`α` is a type parameter, like `T` in a TypeScript generic. The interesting part is `Quote request`. Its argument is an actual request value, including the order and the request number.

An `Array<Ticket>` tells us what kind of thing is inside. A `Quote request` also tells us which input the result belongs to.

The price formula here is deliberately small: items plus the selected fulfillment charge. `Priced` supplies that formula; we will come back to it. The `correct` field requires the amount to agree with it.

For a real server quote, the server remains responsible for price, availability, and expiry. The useful frontend relationship is still the same: keep the accepted result attached to its request.

**Keep the lifecycle together too.**

```lean
inductive Checkout (α : Type) [Priced α] where
  | editing (input : α)
  | loading (request : Request α)
  | ready (request : Request α) (quote : Quote request)
  | failed (request : Request α) (message : String)
```

We have one state instead of separate `loading`, `error`, `quote`, and `canPay` fields. The UI derives the spinner and button state from this value.

The ready case requires a matching request and quote. Trying to put the delivery quote beside the pickup request is a type error. Changing the selection returns checkout to editing. It needs a new quote before it can become ready again.

The network still runs at runtime. When a response arrives, the code compares its request with the current one. A match gives Lean the evidence needed to accept it. A mismatch leaves the state alone.

The request number matters too. A customer can request another quote for exactly the same order. Matching the cart alone would not distinguish those requests.

This is why a frontend developer should care about dependent types: a function can require the relationship it relies on. The developer still writes the boundary check. Code after that check gets to rely on it.

**Now make the behavior reusable.**

We need prices for items, pickup, and delivery. A type class describes that shared capability:

```lean
class Priced (α : Type) where
  price : α → Nat
```

This is close to an interface or trait. An `instance` supplies the implementation for a type. Lean finds the implementation when a function asks for `[Priced α]`.

In the example, items cost quantity times unit price. Pickup costs zero. Delivery costs $5 or $12, depending on speed.

Then we describe how prices compose:

```lean
instance [Priced α] [Priced β] : Priced (α × β) where
  price pair := price pair.1 + price pair.2

instance [Priced α] [Priced β] : Priced (α ⊕ β) where
  price choice := match choice with
    | .inl left => price left
    | .inr right => price right
```

Both parts? Add their prices. Either part? Price the selected one.

Lean can now assemble pricing for `Items × (Pickup ⊕ Delivery)` from the smaller implementations. We did not write a special pricing implementation for that whole type.

Add a gift wrapping type and its price implementation. The existing composition rule can price `Input × GiftWrap`. The same checkout lifecycle can use it too.

This additive rule assumes the charges are independent. A coupon that changes the shipping fee needs a rule that sees both values. Type classes do not invent that business rule for us.

For one widget, passing a pricing function as a prop would also work. Type classes become useful when many functions share a capability and implementations can be assembled from smaller ones.

There is another type class already helping here: `DecidableEq`. Deriving it gives us an equality check for a record, including its fields. Lean can assemble equality for the nested order and request from those smaller checks. Adding a field to the input does not require remembering to add it to a handwritten comparison.

**Let the user finish typing.**

A quantity field will briefly be empty while someone edits it. That is a normal draft, even though a submitted order needs a positive quantity.

```lean
abbrev Quantity := { n : Nat // 0 < n ∧ n ≤ 99 }
```

This means a number from 1 to 99, together with evidence that it is in range. The parser checks the draft at runtime. A successful result can be used wherever a checked quantity is required.

The UI can keep the empty string and show an error. It does not need to force every keystroke into a valid order.

LeanReact already provides another useful kind of composition here. `DraftParser.product` combines independent field parsers and collects their errors. `DraftParser.checked` adds a rule that depends on the combined result. For example, check an address and a shipping choice separately, then check whether that service reaches that address. Each parser can be reused in another form.

**What actually gets smaller?**

These tools have different jobs:

| Tool | What it buys us in checkout |
|---|---|
| Alternatives (`inductive`, `⊕`) | Only the selected fulfillment choice carries data. |
| Products (`structure`, `×`) | Independent pieces can be built and understood separately. Their valid combinations remain. |
| Generics (`Checkout α`) | One lifecycle works for several kinds of order. |
| Dependent types (`Quote request`) | Related values must agree about which request they belong to. |
| Checked values (`Quantity`) | Later code can rely on a rule established during validation. |
| Type classes (`Priced`, `DecidableEq`) | Shared behavior can be assembled from smaller implementations. |
| Parser combinators | Small input checks combine into larger form checks. |

Twenty independent fields with four choices still have 4²⁰ combinations. Types cannot remove choices the product really supports. They can remove invalid combinations, avoid storing values we can derive, and let shared code handle many valid combinations without listing each one.

The promise for the reader is practical: fewer places where changing one field silently leaves another value wrong.

**A demo worth building from this story.**

Start with two mugs and delivery selected. Show a delayed quote request. Switch to pickup before it finishes. Let the old reply arrive and show that the current checkout is still waiting for its own quote. Then show $24 and enable payment when the matching reply arrives.

Beside it, show the short line that tries to attach the delivery quote to the pickup request, and the compiler error. A separate gift wrap toggle can show the composed total becoming $27 through the same checkout code.

The supporting [Lean model](Checkout.lean) includes the late-success, late-failure, same-input retry, quantity-validation, and composed-price cases. Run it with `lake env lean docs/blog/workshop/Checkout.lean`.

References: [Lean type classes](https://lean-lang.org/doc/reference/latest/Type-Classes/), [dependent types](https://lean-lang.org/functional_programming_in_lean/Programming-with-Dependent-Types/Indexed-Families/), [subtypes](https://lean-lang.org/doc/reference/latest/Basic-Types/Subtypes/), and the repository's [form combinators](../../../engine/LeanReact/Forms.lean).
