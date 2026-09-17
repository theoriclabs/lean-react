# Stop storing independent copies of derived facts

[All guides](README.md) · Checked examples: `Derived` in [GuideExamples.lean](GuideExamples.lean), [Checkout.lean](../Checkout.lean)

A cart stores quantity, unit price, shipping, and total. The customer changes quantity. One event handler updates the total; another forgets. The screen now holds two conflicting accounts of the same purchase.

If a value is determined by other values, computing it is usually the simplest fix.

**Start with a function**

```lean
structure Cart where
  quantity : Nat
  unitPrice : Nat
  shipping : Nat

def Cart.total (cart : Cart) : Nat :=
  cart.quantity * cart.unitPrice + cart.shipping
```

There is no stored total to synchronize. The same applies to a list's empty flag, whether a mode shows a particular field, or a button state that can be read directly from the current workflow case.

This benefit is available in ordinary programming too. Lean adds another option when you have a reason to store the result: put its required relationship in the type.

**A stored value can carry an agreement rule**

```lean
structure PricedCart where
  cart : Cart
  total : Nat
  agrees : total = cart.total

def price (cart : Cart) : PricedCart :=
  ⟨cart, cart.total, rfl⟩

def resize (priced : PricedCart) (quantity : Nat) : PricedCart :=
  price { priced.cart with quantity }
```

The equality field requires the stored total to match the formula. `rfl` proves the constructor's equality because both sides are the same computation. Updating quantity calls `price` again, producing a new total and new evidence together. [Equality in Lean](https://lean-lang.org/doc/reference/latest/Basic-Propositions/Propositional-Equality/)

The checked example starts with a total of 1700. Changing quantity from one to two produces 2900. Trying to package the new cart with the old total is rejected.

**Use this when**

Compute derived values by default. Use a stored result with an agreement rule when a public data structure must expose both inputs and a result, or when larger APIs need to preserve that relationship through transformations.

For expensive computations, a cache may be justified. The agreement proof is a correctness contract, not a caching strategy or performance guarantee. You still need a sensible way to establish it without repeating unnecessary work.

Choose an ordinary memoized function for a local rendering optimization. You do not need an equality field just to avoid a cheap calculation during render.

**Separate formulas from outside decisions**

A server quote is often not a deterministic function of the client cart alone. It may depend on promotions, inventory, tax policy, or time. Do not invent a client formula and call its proof evidence that the server price is right.

Instead, use [shared context](03-shared-context.md) to tie the server's quote to its request, and include relevant versions when the contract requires them. Use an equality rule only for a relationship you actually define and can establish.

The teaching formula uses natural-number minor units and omits tax and discounts. Extending a real pricing policy requires deciding the rounding and business rules as well as changing the type.

**Where the large reduction comes from**

Twenty independent fields with four choices each allow 4²⁰ = 1,099,511,627,776 combinations. If only five are independent and the other fifteen are deterministic functions of those five, there are at most 4⁵ = 1,024 configurations.

That reduction follows from the stated dependencies. It does not happen just because the fields are nested inside records. Computing derived fields removes their independent choices; equality constraints can rule out disagreement when they remain stored.

**Introduce it safely**

Identify which value is the source of truth. Replace writes to derived state with a function of that source. If the result remains stored, funnel construction and updates through functions that preserve the equation. Validate persisted data at the boundary; an old cache is not a proof.

Check every input that affects the result, policy changes, and restored stale values. A useful check changes one input and verifies that no old result can silently survive as an accepted value.
