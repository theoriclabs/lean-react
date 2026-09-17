# Treat equivalent representations as one domain value

[All guides](README.md) · Checked example: `Equivalent` in [GuideExamples.lean](GuideExamples.lean)

A customer selects seats A and B. Another interaction selects B and then A. If selection order has no meaning, both describe the same purchase. An array comparison may still treat them as different, triggering an unnecessary update or missing a cache hit.

Sometimes a large state space contains many representations of the same meaningful state. You can remove that duplication too.

**Start with a canonical representation**

For two seats, store them in increasing order:

```lean
abbrev OrderedSeats :=
  { pair : Fin 4 × Fin 4 // pair.1 < pair.2 }

def canonical (first second : Fin 4) : Option OrderedSeats :=
  if h : first < second then some ⟨(first, second), h⟩
  else if h : second < first then some ⟨(second, first), h⟩
  else none
```

Both `(0, 1)` and `(1, 0)` become `(0, 1)`. Equal seats are rejected. Consumers receive one chosen representation instead of having to ignore order independently at every call site.

With four seats, there are 16 ordered pairs. Requiring different seats leaves 12. Ignoring order leaves six meaningful selections. Distinctness removes invalid pairs; canonicalization removes duplicate representations. Those are separate operations.

**Use this when**

Use normalization when order, spelling, or another representation detail truly has no domain meaning. Examples include an unordered filter selection, a set of tags, or a cache key built from a map whose entry order should not matter.

Choose an ordinary sequence when order is meaningful. Seat assignments to two named passengers are not an unordered selection. User-entered order may also matter for display, accessibility, or an audit trail. You can retain presentation history separately while normalizing a domain key.

Write the equivalence rule in plain language first. If the product cannot say which differences are irrelevant, the type system cannot decide for it.

**The more general option: a quotient**

A quotient says which values should count as equal without requiring one chosen stored representation. The checked example first defines distinct seat pairs, then a `Setoid` whose relation compares their sorted keys:

```lean
abbrev SeatSet := Quotient sameSelection
```

`sameSelection` contains the equivalence relation and proofs that it is reflexive, symmetric, and transitive. The example proves that the quotient values built from `(0, 1)` and `(1, 0)` are equal. [Quotients in Lean](https://lean-lang.org/doc/reference/latest/The-Type-System/Quotients/)

To define an ordinary value-producing operation on this quotient, show that it gives the same result for equivalent representations. Counting selected seats works. Returning “the first selected seat” does not respect this equivalence, since swapping the pair changes that answer.

**When a quotient is worth it**

Use a quotient when you need to reason about equivalence throughout an API and choosing a convenient canonical form is difficult or undesirable. It is often most useful in a mathematical or domain library.

For typical frontend state, normalization is easier to inspect, serialize, compare, and debug. A quotient does not automatically sort storage, choose a representative, supply an efficient hash, or reduce the amount of UI code. Its benefit is the equality contract.

**Adopt it at a boundary**

Normalize external input before constructing the accepted value. Use that value consistently for equality, keys, and downstream operations. Do not let one component normalize while another compares the original representation.

Check swapped inputs, duplicates, and already normalized inputs. Normalizing an accepted representation again should preserve it. For a quotient, check that each public operation respects the equivalence relation.

Combine this with [dependent collections](06-dependent-collections.md) when membership and count also matter. First decide which selections are valid. Then decide which valid representations mean the same selection.
