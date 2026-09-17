# Compose parsers along with their contracts

[All guides](README.md) · Checked example: `Editor` in [StateSpaceComposition.lean](../StateSpaceComposition.lean)

You have a quantity parser and a date parser. Then you build a pair, a date range, and a larger booking form. Rewriting the validation for every combination is tedious. It also makes it easy to lose a rule while assembling the larger form.

A type class can associate each accepted type with its draft type and parser. Instances for compound types can reuse the smaller contracts.

**The model**

```lean
class Editor (Value : Type) where
  Draft : Type
  parse : Draft → Except String Value
  format : Value → Draft
  roundtrip : ∀ value, parse (format value) = .ok value
```

`Draft` is an associated type: it depends on which `Editor` instance is chosen. `parse` returns either an error or a value of the promised type. `format` turns accepted data back into a draft. `roundtrip` requires that formatting an accepted value and parsing it again succeeds with that value.

This class contains both operations and a law about them. Lean checks the law supplied by each instance. Type classes can carry such contracts, but an ordinary class without laws does not acquire them automatically. [Lean's type classes](https://lean-lang.org/doc/reference/latest/Type-Classes/)

**How the pieces compose**

The checked file provides three instances:

| Accepted type | Draft type | Parser behavior |
|---|---|---|
| `Nat` | `Nat` | Accept the number. |
| `A × B` | `Editor.Draft A × Editor.Draft B` | Run both component parsers. |
| `{ a : A // P a }` | `Editor.Draft A` | Parse `A`, then check `P`. |

The natural-number draft keeps this example focused on composition. A real text input would commonly use `String` instead.

Now define the accepted booking window:

```lean
abbrev Day := { n : Nat // 1 ≤ n ∧ n ≤ 4 }
abbrev Window := { pair : Day × Day // pair.1.val ≤ pair.2.val }

def readWindow (draft : Nat × Nat) : Except String Window :=
  Editor.parse draft
```

Lean assembles the parser through two levels of refinement and a product. It checks each day and then their order. The file also proves that the compound instances preserve the round-trip law. The final draft type reduces to `Nat × Nat`.

This is where reusable behavior and state constraints meet. The subtype defines accepted values. The class machinery builds operations that preserve that choice of type.

**Use this when**

Use it when many accepted types have a predictable default parser and formatter, and compound forms repeatedly need the same composition rules. It is valuable in a form library or domain-modeling layer.

Choose explicit parser records when the same type has several equally useful editors: cents versus decimal currency input, different locales, or rules chosen by a tenant at runtime. Passing an editor explicitly makes that choice visible. It also avoids competing global instances.

**Keep the editing experience under your control**

Store the raw draft while the user types. Parsing can fail without destroying that draft. Construct the accepted value when the form needs it, and display useful errors near the relevant fields.

The generic parser here stops at the first error and uses a generic message for a failed refinement. A production form may want field paths and several errors at once. LeanReact's [form implementation](../../../../engine/LeanReact/Forms.lean) is a separate place to study draft parsing; this teaching class is not its API.

Do not run `format` over the draft on every keystroke just because the law exists. The law says `parse (format value)` preserves accepted values. It does not say `format (parse draft)` preserves every spelling, cursor position, or incomplete input.

**What to check**

The example checks invalid individual days, reversed windows, valid same-day windows, and all 16 pairs in the four-day model. Ten are accepted. Also check application-specific error placement, default values, and whether instance selection chooses the intended editor.

Start with [relational refinements](04-relational-refinements.md) if you only need one validator. Add this layer when composing those validators has become a recurring task.
