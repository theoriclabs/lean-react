# Keep collection size, membership, and uniqueness together

[All guides](README.md) · Checked examples: `Collections` in [GuideExamples.lean](GuideExamples.lean), `TwoSeats` in [StateSpaceComposition.lean](../StateSpaceComposition.lean)

A customer buys two theatre tickets. The form should select two different seats, both from the chosen performance. A plain array can contain one seat, the same seat twice, or a seat left over from the evening show.

Those are three different rules. They need three different parts of the model.

**The model**

```lean
structure Show where
  id : Nat
  revision : Nat
  available : List Nat
  deriving DecidableEq

structure Seat (performance : Show) where
  number : Nat
  available : number ∈ performance.available

structure Selection (performance : Show) (count : Nat) where
  seats : Vector (Seat performance) count
  distinct : (seats.toList.map fun seat => seat.number).Nodup
```

`Seat performance` ties a seat to a particular show snapshot and requires membership in its available list. `Vector ... count` requires the requested number of entries. `Nodup` requires different seat numbers.

The constraints compose. A vector alone guarantees length, but allows duplicates. A list of valid seats can still have the wrong length. A membership check alone does not say which performance the selection is for.

These are examples of types indexed by values, combined with ordinary propositions. [Indexed families in Lean](https://lean-lang.org/functional_programming_in_lean/Programming-with-Dependent-Types/Indexed-Families/)

**Use this when**

Use it for ticket selection, allocations, tables with required columns, or tasks where the number and identity of selected items matter to downstream code. It is especially useful for a confirmed selection that passes through several functions.

Choose a plain array of stable IDs for an unfinished selection. Choose ordinary validation if the array is immediately submitted and nothing else assumes its shape. Put stronger types at the accepted-selection boundary first.

**Introduce one constraint at a time**

1. Keep a draft list of selected seat IDs. It may be incomplete.
2. Resolve every ID against the current show snapshot.
3. Check the requested count and distinctness.
4. Return a `Selection performance count` only after all checks pass.

The example supplies `checkSeat` for the membership boundary and constructs a checked two-seat selection. A complete form would also implement the count and duplicate error messages. The example does not implement a seat-booking backend.

When the ticket count changes, the old selection has the old count in its type. Let the customer finish editing before accepting the new selection. When the show changes, resolve the IDs again; matching seat numbers do not make them seats for the same event.

**Bounds do not establish identity**

`Fin n` is useful for an index known to be below `n`. It does not identify a particular list. Two unrelated lists can have the same length, and a reorder can change what an index points to. Use stable keys or include the actual collection context when identity matters.

The `Seat` structure above retains the whole performance parameter, including its ID and revision. The checked example rejects mixing two shows even when their available seat lists are identical.

Availability is still a snapshot. Another customer may buy a seat after it was displayed. The reservation service must handle that conflict and return a fresh result.

**What gets smaller**

Choosing two ordered seats from four gives 4² = 16 pairs. Requiring distinctness leaves 12. If order has no meaning, those 12 describe only six selections; [equivalent representations](13-equivalent-representations.md) handles that separate reduction.

Check empty and incomplete drafts, repeated IDs, unknown IDs, count changes, and a different show with the same seat numbers. Count, membership, identity, and distinctness should each have their own check.
