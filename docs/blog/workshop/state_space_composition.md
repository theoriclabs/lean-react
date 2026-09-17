# Composing types to remove invalid states

The useful question is which relationships can become part of a type, and whether those relationships survive composition.

Twenty fields with four choices each allow 4²⁰ = 1,099,511,627,776 combinations. Suppose only five fields are independent choices, and the other fifteen are determined by them. The actual configuration space then has at most 4⁵ = 1,024 states. We can compute the dependent fields, or require evidence that stored values agree with those computations.

That example assumes deterministic dependencies. Other rules remove fewer combinations. We supply the rules; Lean does not discover business dependencies automatically.

This catalog organizes patterns by the relationship they express. They are combinations of type constructions, not a claim that Lean has a separate primitive for every row. The [broader type catalog](type_catalog.md) supplies the vocabulary. The examples below are checked in [StateSpaceComposition.lean](StateSpaceComposition.lean).

Each pattern now has a [detailed guide](guides/README.md), with a real scenario, checked Lean examples, advice on when to use it, and a simpler alternative. The links in the first column go to those guides.

**A catalog of composable constraints**

| Pattern | Ingredients | Dependency made explicit | Example of what disappears |
|---|---|---|---|
| [Conditional structure](guides/01-conditional-structure.md) | Sums plus products | Which fields exist depends on a selected case. | A pickup order with a delivery slot. |
| [Dependent choices](guides/02-dependent-choices.md) | Sigma types plus computed families | Later choices depend on an earlier value. | A shipping service unavailable in the selected country. |
| [Shared-context composition](guides/03-shared-context.md) | One shared index, several indexed types | Several artifacts must belong to the same context. | A cart, quote, and authorization for three different snapshots. |
| [Constraints on a combination](guides/04-relational-refinements.md) | A product refined by a relation | Individually valid fields must also fit together. | Two valid dates in the wrong order. |
| [Multiple constraints on one value](guides/05-combined-predicates.md) | A subtype with a conjunction of predicates | Every rule applies to the same underlying value. | Validating stock for one cart and a coupon for another. |
| [Dependent collections](guides/06-dependent-collections.md) | Indexed containers plus predicates | Length, membership, distinctness, or keys depend on other data. | Three tickets with two seats, duplicate seats, or a selection outside the current list. |
| [A description that determines a type](guides/07-schema-interpreters.md) | A schema language plus a type-valued interpreter | The whole value shape follows the chosen schema or policy. | Form metadata asking for one set of fields while its accepted values allow another. |
| [Composed validation contracts](guides/08-composed-validation.md) | Associated types, generics, refinements, and lawful type classes | The draft and parser are selected from the accepted type; larger parsers preserve the smaller contracts. | A combined form returning a value that violates one of its component rules. |
| [Dependent context chains](guides/09-context-chains.md) | Nested Sigma types and refinements | Each stage carries the context needed by the next. | An appointment slot from another clinic, or a clinician outside the selected clinic. |
| [Compatibility-indexed APIs](guides/10-compatibility.md) | Multiple indices, relation evidence, and possibly type classes | An operation exists only for compatible combinations. | Calling a payment integration with an unsupported method/currency pair. |
| [Indexed transitions](guides/11-indexed-transitions.md) | Source/target indices plus composition | The output state of one step must match the input state of the next. | Composing authorization before obtaining a quote. |
| [Derived-state consistency](guides/12-derived-state.md) | Functions, equality constraints, and controlled construction | A stored result must agree with its inputs. | A subtotal that disagrees with the item quantities. |
| [Equivalent-representation modeling](guides/13-equivalent-representations.md) | Quotients or a canonical representation | Several representations denote one meaningful state. | Counting reorderings of the same unordered selection as different domain states. |

These remove different things. Some rule out data combinations. Some rule out invalid transitions. Others remove redundant representations or allow generic code to handle valid combinations. A type class only narrows permitted combinations when its contract expresses a restriction; a plain rendering or pricing interface primarily provides reuse.

**1. Replace independent choices with conditional choices**

Imagine four countries and four shipping services. The shop actually offers 3, 2, 2, and 1 services in those countries.

The flat model permits 4 × 4 = 16 combinations. The dependent model has 3 + 2 + 2 + 1 = 8.

Conceptually, its type is:

```text
(country : Country) × AvailableService country
```

There are two useful implementations. A computed family can supply a different service type for each country. Alternatively, `AvailableService country` can be a subtype of all services, with proof that the selected one serves that country.

The second approach preserves common service identities while expressing availability as a relation. [Dependent pairs](https://lean-lang.org/doc/reference/latest/Basic-Types/Tuples/), [subtypes](https://lean-lang.org/doc/reference/latest/Basic-Types/Subtypes/)

**2. Give related artifacts one shared context**

Suppose the cart, quote, and authorization each independently name one of four snapshots. Their ownership labels alone admit 4 × 4 × 4 = 64 combinations. Only four triples agree.

A combined value can share the snapshot instead:

```lean
abbrev ReadyCheckout :=
  (snapshot : Fin 4) × Quote snapshot × Authorization snapshot
```

`Fin 4` makes the small example countable. A real model can use a complete request value, including its inputs and generation.

The quote and authorization no longer choose unrelated snapshots. Each is required to use the shared one. Further artifacts can reuse the same index: tax calculation, inventory reservation, or currency-specific amounts.

The relationship can go deeper. An authorization can belong to the exact quote, which itself belongs to the snapshot:

```lean
structure ReadyChain where
  snapshot : Fin 4
  quote : Quote snapshot
  authorization : QuoteAuthorization quote
```

The checked example rejects replacing the quote while retaining its previous authorization, even when the snapshot stays the same.

Mathematically, aligning values over a common context is related to a fiber product, or pullback. The practical rule is simpler: independently reusable pieces can require the same context when assembled.

Indexing a value records an association. Its producer or decoder still has to establish that association. A freely callable constructor is not evidence that a server authorized a payment.

**3. Put the rule on the pair**

Two independently valid dates do not necessarily make a valid range.

For four possible days, a flat start/end pair has 16 combinations. Requiring `start ≤ end` leaves 10.

```lean
abbrev Day := { n : Nat // 1 ≤ n ∧ n ≤ 4 }
abbrev Window := { pair : Day × Day // pair.1.val ≤ pair.2.val }
```

This combines two refinements on individual fields with a third refinement on their product. The outer rule catches a dependency that neither field validator can see alone.

The same pattern applies to “discount does not exceed subtotal,” “end time is after start time,” and “allocated stock does not exceed available stock.”

There is another distinction worth preserving:

```text
CheckedBy P × CheckedBy Q
```

contains two values, which may differ. By contrast:

```text
{ value // P value ∧ Q value }
```

checks one value against both rules. That distinction matters when separate services validate related snapshots.

**4. Let the type of the whole form determine its parser**

This is a stronger type-class example than merely sharing a pricing function:

```lean
class Editor (Value : Type) where
  Draft : Type
  parse : Draft → Except String Value
  format : Value → Draft
  roundtrip : ∀ value, parse (format value) = .ok value
```

The class has an associated draft type. Its parser must return the requested accepted type. Its law says that formatting an accepted value and parsing it again returns that value.

We supply three reusable instances:

1. A base editor for numbers.
2. An editor for a product, built from editors for its parts.
3. An editor for a refinement, built from an editor for its base type and an executable predicate check.

Lean can then assemble the editor for `Window`:

```text
Editor Window
  refinement: start ≤ end
    product
      refinement: 1 ≤ start ≤ 4
        number editor
      refinement: 1 ≤ end ≤ 4
        number editor
```

The resulting draft type is an ordinary pair of numbers. The accepted type is the constrained window. No special `Editor Window` instance is needed.

The executable example accepts `(1, 4)` and `(3, 3)`. It rejects `(4, 1)`, `(0, 2)`, and `(2, 5)`. Its generic product and refinement instances also prove the round-trip law from the laws of their parts.

This is how classes and dependent types contribute together. Refinements restrict values. Type-class instances assemble parsers that return those refined values. Law fields let us check a property of each composition rule once. This parser uses a single error result; collecting every field error is a separate design choice.

A UI renderer could be added to such an interface, but the example here only implements the model, parsing, formatting, and laws. [Type classes and law-bearing interfaces](https://lean-lang.org/doc/reference/latest/Type-Classes/)

**5. Compose descriptions of types**

The next level is to represent the form's shape as data, then interpret that description as a Lean type.

Our checked example defines these constructors:

```lean
inductive Shape where
  | choice (options : Nat)
  | both (left right : Shape)
  | either (left right : Shape)
  | depending (options : Nat) (rest : Fin options → Shape)
```

There are two interpreters:

```text
Shape.Value : Shape → Type
Shape.count : Shape → Nat
```

The first computes the allowed value type. The second computes a finite count using the composition rules: multiply for “both,” add for “either,” and sum the branch counts for “depending.” The example checks concrete counts; it does not include a general proof that the count interpreter matches every interpreted type.

For a small checkout, assume pickup allows four stores. Delivery allows three addresses, each with two slots:

```lean
def fulfillment : Shape :=
  .either (.choice 4) (.both (.choice 3) (.choice 2))
```

This description computes both the type of valid values and the count 4 + 3 × 2 = 10. A flat model holding mode, store, address, and slot would admit 2 × 4 × 3 × 2 = 48 combinations, many differing only in inactive fields.

The `depending` constructor goes further: the first answer selects the entire remaining shape. It can describe a country-dependent shipping form or an account-type-dependent onboarding form.

This is often called the universe pattern: small codes describe types, and an interpreter gives their meaning. It is different from Lean's universe levels such as `Type u`. Lean's [typed-query example](https://lean-lang.org/functional_programming_in_lean/Programming-with-Dependent-Types/Worked-Example___-Typed-Queries/) uses this approach to tie a row's type to its schema.

The same description can guide validation or rendering. Keeping those interpretations consistent may require further types or laws; one shared schema alone does not prove an arbitrary renderer correct.

**6. Combine collection shape with collection meaning**

`Vector Seat ticketCount` requires the correct number of entries. It does not ensure those entries are different.

Add a predicate on the whole vector:

```lean
abbrev TwoSeats :=
  { seats : Vector (Fin 4) 2 // seats.toList.Nodup }
```

There are 4² = 16 ordered pairs of seats, but only 4 × 3 = 12 without duplicates. If order does not matter, those pairs describe six distinct two-seat sets.

Membership can depend on actual data too. A selected item can carry evidence that its key occurs in the current result set. An index of type `Fin items.size` only guarantees a valid position; it does not identify which list of that size the position was selected from.

For appointments, a whole chain can depend on earlier selections:

```text
clinic
  clinician belonging to clinic
    available slot for that clinician
      reservation for that exact slot
```

Each piece remains reusable. The assembled type states how their contexts must agree.

**7. Constrain operations and their composition**

A multi-parameter constraint can express that a provider supports a currency, or that a shipping method is available for a destination. A type class can supply evidence for combinations known during elaboration. Runtime choices still require a runtime check or a package containing the corresponding evidence.

For a workflow, types can index both ends of an operation:

```text
quote     : Step editing quoted
authorize : Step quoted authorized
```

A composition requires the intermediate indices to match. The sample defines a `Path` type that accepts quote followed by authorization and rejects starting an editing path with authorization.

This reduces allowed paths, rather than merely reducing the number of stored data values. It does not make a value single-use or enforce an external transaction by itself.

**Where the largest reductions come from**

The number of fields is often larger than the number of genuine choices. Selected rows depend on loaded rows. A quote depends on a request. A button's enabled state depends on the workflow. A form's fields depend on its mode.

Make independent choices explicit. Compute what follows from them. Where dependent results must be stored, give them types that retain their relationships. Then compose validators and operations that preserve those relationships.

The main combinations worth developing for the blog are:

- A dependent record containing several artifacts with one shared request index.
- A product of refined fields, itself refined by cross-field rules.
- A type class whose associated draft type and lawful instances compose over those accepted types.
- A schema whose interpretation computes the entire allowed form shape.

These are capabilities of dependent typing and compositional design, not exclusive inventions of Lean. Their value here is that Lean lets the same language express the data, executable checks, and proofs connecting them.
