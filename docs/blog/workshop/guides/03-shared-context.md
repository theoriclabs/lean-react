# Keep related results tied to the same request

[All guides](README.md) · Checked examples: [StateSpaceComposition.lean](../StateSpaceComposition.lean), [Checkout.lean](../Checkout.lean)

A customer asks for a delivery quote, then switches to pickup. The delivery response arrives last. Three individually reasonable values now make a bad checkout: the current cart, an old quote, and perhaps an authorization for an earlier amount.

The missing relationship is ownership. Which request does each result belong to?

**The model**

Give every related result the same context parameter:

```lean
structure Quote (snapshot : Fin 4) where
  amount : Nat

structure Authorization (snapshot : Fin 4) where
  reference : String

abbrev ReadyCheckout :=
  (snapshot : Fin 4) × Quote snapshot × Authorization snapshot
```

Read the last line from left to right. Choose a snapshot. Then supply a quote and an authorization for that snapshot. You cannot assemble it from `Quote 0` and `Authorization 1`.

This is a dependent pair containing indexed types. The shared parameter is what connects otherwise reusable pieces. [Lean's dependent pairs](https://lean-lang.org/doc/reference/latest/Basic-Types/Tuples/)

The four snapshots make the example countable. Three independent ownership labels permit 4³ = 64 combinations. Sharing one label leaves four. That counts labels only; amounts and reference strings still have their own values.

**Use this when**

Use it when async results must agree on their inputs: a quote and cart, search results and filters, a preview and document revision, or an inventory reservation and order. It pays off when several modules produce or consume these results.

Choose a simpler request-key comparison when one small component owns the whole lifecycle. You can introduce the indexed types later at the point where results cross a module boundary.

**What happens at runtime**

Runtime responses do not arrive with a compiler certificate. The full checkout example makes the boundary explicit:

1. `begin` captures the complete input and a new generation in a `Request`.
2. A `Reply` carries that request and its result.
3. `receive` compares the reply's request with the current one.
4. Only the matching branch can install the quote in the current ready state.

The equality check supplies the evidence needed to align the types. Both old successes and old failures are ignored. A generation matters even when the user retries without changing any fields: identical inputs can still belong to different attempts.

An edit returns the checkout to an editing state. A new request starts separately. Old data may still be shown as a preview, but it should not become the payable quote for the new request.

**Choose the context carefully**

Include whatever changes the meaning of the result: items, quantity, currency, fulfillment, and a generation or revision where needed. Indexing only by customer ID would still let two carts for that customer get mixed together.

The small `Quote` constructor above is public. It records an association; it does not verify a server signature or establish that money was authorized. A production decoder or producer must establish the association before returning the indexed value. The full checkout example calculates its own demo prices; it is not a payment gateway.

**Compose it further**

Several results can share a snapshot. If an authorization must instead refer to the exact quote, use a [context chain](09-context-chains.md). A matching snapshot alone would allow two differently priced quotes for that snapshot.

Check out-of-order success, out-of-order failure, edits during loading, retries with unchanged inputs, and duplicate replies. The checkout example exercises these cases. These are the situations where a model that looks correct on a happy path often comes apart.
