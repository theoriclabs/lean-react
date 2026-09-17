# Let a description determine the value type

[All guides](README.md) · Checked example: `Shape` in [StateSpaceComposition.lean](../StateSpaceComposition.lean)

A form builder describes pickup and delivery. Its metadata says that pickup asks for a store. Elsewhere, a handwritten data type still requires an address and a delivery slot. The descriptions have drifted apart.

Lean can compute a type from a description. Composing descriptions can then compose their accepted value types too.

**The model**

Here is a small language for describing choices:

```lean
inductive Shape where
  | choice (options : Nat)
  | both (left right : Shape)
  | either (left right : Shape)
  | depending (options : Nat) (rest : Fin options → Shape)
```

`both` asks for two things. `either` selects a branch. `depending` lets an earlier choice determine the rest of the description.

An interpreter turns each description into a Lean type:

```lean
def Shape.Value : Shape → Type
  | .choice n => Fin n
  | .both left right => left.Value × right.Value
  | .either left right => left.Value ⊕ right.Value
  | .depending n rest => (choice : Fin n) × (rest choice).Value
```

The return value of this function is a type. For a particular description `s`, accepted data has type `s.Value`. This use of dependent types is sometimes called a universe of descriptions. That name refers to a small language of shapes, not Lean's `Type u` universe levels. [A worked example of types computed from descriptions](https://lean-lang.org/functional_programming_in_lean/Programming-with-Dependent-Types/Worked-Example___-Typed-Queries/)

**A complete small example**

```lean
def fulfillment : Shape :=
  .either (.choice 4) (.both (.choice 3) (.choice 2))
```

Pickup chooses one of four stores. Delivery chooses one of three addresses and one of two slots. Its value type is `Fin 4 ⊕ (Fin 3 × Fin 2)`. There is nowhere to attach a delivery slot to the pickup branch.

The source also defines a counting interpreter. It adds for alternatives, multiplies for independent choices, and sums the available branches for dependent choices. This fulfillment description counts to 10. The shipping description, with 3, 2, 2, and 1 available services, counts to eight.

Those concrete counts are checked. The file does not prove a general theorem that the counting interpreter always equals the number of values in the interpreted type.

**Use this when**

Use it when many forms, messages, or workflows share a common description language. It can keep accepted data, codecs, and other operations aligned with that language.

Choose handwritten structures and variants for a few ordinary forms. A schema language introduces its own design work: field identity, labels, errors, defaults, migrations, and custom behavior. It pays off when many consumers would otherwise repeat the same interpretation.

**Build it gradually**

Start with primitive fields and products. Add alternatives for genuine mode switches. Add dependent branches when earlier values determine later shapes. Implement a decoder that returns the interpreted type, then connect the form to that decoder.

A renderer is another interpreter you could build. It is not supplied by this example, and having a typed schema does not by itself prove that every rendered widget or label is correct. Add laws or checks for the relationships you need, such as decoding an encoded value successfully.

Keep drafts separate. An empty text box needs a representation even when the accepted schema demands a number. [Composed validation](08-composed-validation.md) shows one way to derive draft shapes alongside accepted types.

**Runtime schemas still need a boundary**

A schema loaded from JSON must itself be decoded and validated. The function-valued `depending` constructor here is convenient Lean code; it is not directly a JSON format. A production format needs explicit branch descriptions and supported rules.

When a schema changes, old values may need migration. Package the schema with its value, or track its version, instead of pretending that all configurations share one shape.

Check each constructor, nested combinations, unavailable branches, and schema changes. Keep the description language small enough that its interpreters remain understandable.
