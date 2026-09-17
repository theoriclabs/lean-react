# Give each mode its own fields

[All guides](README.md) · Checked example: `Conditional` in [GuideExamples.lean](GuideExamples.lean)

A customer switches from delivery to pickup. The address field disappears, but the old delivery slot and shipping fee remain in state. Another component still reads them.

This is a sign that the model stores fields for several mutually exclusive cases at once. A tagged variant can make the active case explicit.

```lean
inductive Fulfillment where
  | pickup (details : Pickup)
  | delivery (details : Delivery)
```

`Pickup` contains a store. `Delivery` contains an address and slot. The selected fulfillment value carries one payload. Code that reads a delivery slot must first establish that it has the delivery case.

The complete example is in the `Conditional` namespace of [GuideExamples.lean](GuideExamples.lean). Its description function matches both branches, and its rejection check tries to pass a delivery payload to the pickup constructor.

**What becomes smaller**

Suppose there are four stores, three addresses, and two delivery slots. A flat model containing a two-way mode plus all three fields admits 2 × 4 × 3 × 2 = 48 combinations. The configured variant admits 4 + 3 × 2 = 10. This counts only those finite choices. Many removed combinations were different leftovers for the same selected mode.

**Use this when**

Fields or controls exist only in particular modes: personal versus business accounts, pickup versus delivery, editing versus submitted, password versus passkey setup. It also helps when a collection of optional fields requires comments explaining which combinations are meaningful.

**Choose something simpler when**

The choices are independent. Size and milk belong together if every milk works with every size. A record is suitable there. Do not turn every checkbox into a top-level variant; that can create a long list of combinations you actually intend to support.

**Introduce it gradually**

1. Name the mutually exclusive cases and the data each needs.
2. Create one type for the selected value. Convert the old record at one boundary.
3. Move the branch-specific reads into matches on that value.
4. Update the selected case in one state operation, rather than setting a mode and clearing several fields separately.

Keep editable memory distinct from the selected domain value. A draft may remember the previous address so switching back is pleasant. That address should not silently become part of the current pickup order. Initial “nothing selected” can be another case or an `Option`, depending on what the screen needs to display.

**Composition and checks**

Combine independent items with fulfillment using a product. Use a [dependent choice](02-dependent-choices.md) when a selected country changes the allowed delivery services. Use a [relational refinement](04-relational-refinements.md) when an address and service must fit together within the delivery case.

Check mode switching, restoring a remembered draft, and rendering every case. Exhaustive matching covers constructors; it does not prove that each branch shows the right label or that a wildcard renders something useful. This technique is also available through TypeScript discriminated unions. See [Lean's inductive types](https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/).
