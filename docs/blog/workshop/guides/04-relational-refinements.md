# Validate the relationship between fields

[All guides](README.md) · Checked examples: [StateSpaceComposition.lean](../StateSpaceComposition.lean), `Relations` in [GuideExamples.lean](GuideExamples.lean)

A booking form has two valid dates. The start is Thursday. The end is Tuesday. Each field passes its own validator, but the booking makes no sense.

The rule belongs to the pair, so put it on the pair.

**The model**

```lean
abbrev Day := { n : Nat // 1 ≤ n ∧ n ≤ 4 }
abbrev Window :=
  { pair : Day × Day // pair.1.val ≤ pair.2.val }
```

`Day` accepts one of four days. `Day × Day` holds two individually valid days. The outer subtype adds a relationship: the start is no later than the end.

A subtype is a value together with evidence that a stated rule holds. A function accepting `Window` can rely on that rule without checking it again. [Lean's subtypes](https://lean-lang.org/doc/reference/latest/Basic-Types/Subtypes/)

Here there are 16 possible pairs and 10 accepted windows. Same-day windows count as valid because the rule uses `≤`. A hotel that requires at least one night needs `<` instead. The type enforces the rule you wrote, so choosing that rule is still product work.

**Use this when**

Use a relational refinement when individually valid parts may fail together. Examples include a discount larger than the subtotal, allocations larger than a budget, or a selected service that cannot handle the parcel's weight.

It becomes especially useful when several downstream functions assume the relationship. They can accept the checked type instead of each remembering a defensive check.

Choose a plain whole-record validator when the result stays inside one short function. You do not have to publish a new domain type for every temporary comparison. Use a [variant](01-conditional-structure.md) instead when the real rule is that a field only exists in one mode.

**Keep editing separate from acceptance**

A user changing Tuesday–Thursday to Friday–Sunday may temporarily type Friday–Thursday. That is a useful draft even though it is not an accepted window.

Keep raw inputs in the form. Parse both fields, then check their relationship. The `Relations` example isolates that last check with a simpler window type:

```lean
abbrev Window := { pair : Nat × Nat // pair.1 ≤ pair.2 }

def check (start finish : Nat) : Except String Window :=
  if h : start ≤ finish then .ok ⟨(start, finish), h⟩
  else .error "The end must not be before the start."
```

The successful branch packages the pair with `h`, the evidence obtained from the runtime check. Failure stays a normal result that the form can display.

**Edits invalidate the old evidence**

You cannot safely reuse a proof about Tuesday–Thursday after replacing Tuesday with Friday. An update function should either establish the relationship again or return a draft that still needs validation. `moveStart` in the checked example reuses the whole-window validator and can fail.

This is why independent field setters need care. A reusable setter for the inner record does not automatically preserve every rule on the outer record. Put accepted-value updates behind functions that maintain the whole relationship.

**Compose it further**

This pattern stacks well: validate each field, combine the fields, then validate the combination. [Composed validation contracts](08-composed-validation.md) builds this exact parser from reusable pieces. [Combined predicates](05-combined-predicates.md) adds several rules to the same record.

Check boundary equality, reversed values, individually invalid values, and edits that turn a valid pair into an invalid one. Also check the visible form error. A correct domain model still needs a helpful editing experience.
