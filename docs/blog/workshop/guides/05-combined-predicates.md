# Make several checks concern the same value

[All guides](README.md) · Checked examples: `Intersections` in [GuideExamples.lean](GuideExamples.lean), [StateSpaceComposition.lean](../StateSpaceComposition.lean)

Checkout checks stock and checks a coupon. Both pass. Meanwhile, the customer has changed the quantity. The stock check concerns one cart, while the coupon check concerns another.

Having two successful checks is weaker than having two successful checks of the same thing.

**The model**

Start with a small quantity example:

```lean
def positive (n : Nat) : Prop := 0 < n
def small (n : Nat) : Prop := n < 4

abbrev Positive := { n : Nat // positive n }
abbrev Small := { n : Nat // small n }
abbrev Both := { n : Nat // positive n ∧ small n }
```

`Positive × Small` contains two numbers. One could be 10 and the other 0. `Both` contains one number that passes both checks.

The `∧` is logical “and.” Both predicates receive the same `n`. You can build larger contracts this way without making a separate copy of the domain value for each check. [Propositions in Lean](https://lean-lang.org/doc/reference/latest/The-Type-System/Propositions/)

If separate validators already returned their own values, combining them needs evidence that those values agree:

```lean
def combine (a : Positive) (b : Small)
    (same : a.val = b.val) : Both :=
  ⟨a.val, a.property, same.symm ▸ b.property⟩
```

The last expression uses equality to move the second check onto the first value. The example accepts two checks of 2 and rejects combining a check of 2 with a check of 3.

**Use this when**

Use this when one accepted value must meet several independently defined rules: a password policy, an order ready for submission, or a configuration satisfying several module contracts. It helps when validators compose across boundaries and later code needs all the guarantees together.

Choose a product when you really do want two separate values. Choose a simple Boolean expression when the combined check is local and no later function relies on its result. A shared validator function is often a good first implementation.

**Collect checks around one snapshot**

First capture the input you mean to accept. Pass that snapshot to every check. If the user edits it, the previous evidence stays attached to the previous value. Validate the new value before treating it as accepted.

With async stock or coupon checks, the input is only part of the context. Stock and policies can change on the server. Include a relevant revision or reservation when that matters, and let the server enforce the final transaction. A proposition about a snapshot does not make outside facts remain true forever.

If you need to compare separately returned snapshots at runtime, perform that comparison at the boundary. [Shared context](03-shared-context.md) shows how to keep the resulting association through later composition.

**Validation and error messages are separate choices**

A conjunction states which rules must hold. It does not decide whether the UI reports the first error or all errors. Write the validator to collect the errors the user needs, then construct the accepted value only when all checks pass.

The finite example in `StateSpaceComposition.lean` uses the four numbers 0 through 3. Three are positive, three are below 3, and only two satisfy both. Combining constraints intersects their accepted values. It does not multiply separate successful results.

Check that each rule can fail alone, that both can fail, and that evidence for different values cannot be combined. For async rules, also check edits between responses. [Composed validation](08-composed-validation.md) covers how to reuse these contracts through larger types.
