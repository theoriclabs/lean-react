# A practical catalog of types in Lean

For the narrower question of how combining types can remove invalid states, start with [Composing types to remove invalid states](state_space_composition.md). It covers shared indices, relational refinements, dependent collections, associated draft types, and schemas that compute other types. This page is the broader vocabulary reference.

The [practical guides](guides/README.md) explain when to use each state-modeling pattern, how to introduce it, and when a simpler approach is enough.

Lean lets you define new types, so a catalog cannot list every possible type. This covers the main ways of forming types, the modeling patterns built from them, and the library types a programmer is likely to meet.

The categories overlap. `Quote request` can be a record, a parameterized type, and a dependent type at the same time. Type classes, coercions, and type aliases are included as related tools; they are not separate primitive kinds of type.

The examples use Lean 4.33.0, the version pinned by this repository. This is a catalog of Lean itself. LeanReact's JavaScript compiler supports a [smaller subset](../../IMPLEMENTED.md).

Representative declarations and rejection examples are in [TypeCatalog.lean](TypeCatalog.lean). Run `lake env lean docs/blog/workshop/TypeCatalog.lean` to check them.

**The foundations**

Lean's core has a small set of building blocks. Most familiar types are assembled from them. [Type-system reference](https://lean-lang.org/doc/reference/latest/The-Type-System/)

| Building block | Spelling | Plain meaning | Where it matters |
|---|---|---|---|
| Universes, or sorts | `Prop`, `Type`, `Type u`, `Sort u` | Types themselves have types. Universes organize those levels. | Generic libraries and the distinction between data and proofs. |
| Function types | `A → B` | A function accepts an `A` and returns a `B`. | Callbacks, transformations, render functions. |
| Dependent function types, or Pi types | `(x : A) → B x` | The result's type can depend on the argument's value. | Returning a quote for the exact request supplied. |
| Inductive types | `inductive ... where` | Define a type by listing its constructors. Constructors may carry data. | Variants, recursive trees, and state-indexed values. |
| Quotient types | `Quot r`, `Quotient s` | Treat values related by a chosen relation as equal. `Quotient` uses an equivalence relation packaged in a `Setoid`. | Reasoning about equivalent representations. |

Ordinary function types are a special case of dependent function types. Records, products, sums, and many built-in data types are implemented using inductive definitions. [Functions](https://lean-lang.org/doc/reference/latest/The-Type-System/Functions/), [inductive types](https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/)

`Type` means `Type 0`. `Prop` is `Sort 0`, and `Type u` is `Sort (u + 1)`. For example, `Nat : Type`, while `Type : Type 1`. You rarely need to manage universe levels in an ordinary form component. [Universes](https://lean-lang.org/doc/reference/latest/The-Type-System/Universes/)

**Ways to shape application data**

| Kind or pattern | Example | What it means | Effect on application complexity |
|---|---|---|---|
| Enumeration | `Method.pickup`, `Method.delivery` | One of a fixed set of names. | Names choices instead of using loosely related flags. |
| Product / tuple | `Items × Fulfillment` | Both values exist together. | Organizes independent pieces; their possibilities multiply. |
| Record / structure | `structure Delivery where ...` | A product with named fields. | Groups fields with one purpose. |
| Sum / tagged union / variant | `Pickup ⊕ Delivery` | Either a pickup payload or a delivery payload. | Removes combinations that should not coexist. |
| Algebraic data type (ADT) | A named variant with record-like payloads | A broad name for types built from sums and products, often with recursion. | Describes a domain's cases directly. |
| Recursive type | A rule containing smaller rules | Values can contain values of the same type. | Models trees, nested menus, and rule builders. |
| Mutually recursive types | `Menu` contains `Menus`; `Menus` contains `Menu` | Several types refer to one another. | Describes related recursive structures. |
| Nested inductive type | A tree node with `List (Tree A)` children | Recursive values appear inside another type constructor. | Reuses collections inside recursive models. |
| Extended record | `structure ScheduledDelivery extends Delivery` | A structure includes another structure's fields and adds its own. | Shares a common record shape. |
| Distinct wrapper / newtype pattern | Separate `UserId` and `OrderId` structures | Two values with the same representation have different types. | Prevents mixing identifiers or units. |
| Phantom parameter | `EntityId User`, with only a numeric field | A parameter distinguishes types without storing an additional entity field. | Keeps IDs associated with their entity type. |

Enums, tagged variants, and recursive types are all uses of `inductive`. Structures are a convenient way to declare single-constructor inductive types. Recursive definitions must meet Lean's positivity rules. [Inductive-type tutorial](https://lean-lang.org/theorem_proving_in_lean4/Inductive-Types/)

For example, a rule builder needs more than a flat enum:

```lean
inductive Rule where
  | minimum (amount : Nat)
  | both (left right : Rule)
```

It can represent “minimum order of $20 AND another rule.” It can also nest those combinations. The type describes the tree shape. It does not, by itself, prove that two business rules are compatible.

**Types that express relationships**

These are the main additions to the earlier checkout list. A dependent type is the broad idea: a type can refer to a value. The following are different ways to use that idea.

| Kind or pattern | Example | Relationship it expresses | Possible application |
|---|---|---|---|
| Indexed inductive family; GADT-style modeling | `Order stage` | Constructors produce particular indices. | A ready order carries different data from a draft order. |
| Computed type family | `Details method` | A function computes which type to use. | Pickup needs a store; delivery needs an address. |
| Dependent record | Fields `method` and `details : Details method` | A later field's type depends on an earlier field. | Store the selection and the appropriate details together. |
| Dependent pair / Sigma type | `(m : Method) × Details m` | Package an index and a value of the type selected by that index. | Carry a fulfillment choice that is only known at runtime. |
| Dependent function / Pi type | `(n : Nat) → Vector Item n` | Each input determines the result type. | Return exactly the requested number of entries. |
| Refinement / subtype | `{ n : Nat // 0 < n ∧ n ≤ 99 }` | A value satisfies a predicate. | Checked quantities, valid date ranges, nonempty names. |
| Record containing proofs | `seats`, `count`, and `seats.length = count` | Several fields obey a stated relationship. | One selected seat per ticket. |
| Equality type | `oldRequest = currentRequest` | Two values are equal. | Safely treat a response as belonging to the current request. |
| Heterogeneous equality | `HEq a b` | Compare terms whose types may differ. | Advanced proofs involving dependent representations. |
| Typestate | `Order .draft`, `Order .ready` | An API uses a state index to restrict its inputs and results. | A pricing function accepts only a ready order. |

Typestate is a modeling pattern using indexed types, not an additional primitive. Likewise, a record containing proofs is a dependent record, and a subtype is a standard construction with a value and a proof field. [Indexed families](https://lean-lang.org/functional_programming_in_lean/Programming-with-Dependent-Types/Indexed-Families/), [subtypes](https://lean-lang.org/doc/reference/latest/Basic-Types/Subtypes/), [equality](https://lean-lang.org/doc/reference/latest/Basic-Propositions/Propositional-Equality/)

Here is a computed family and a dependent record:

```lean
def Details : Method → Type
  | .pickup => Pickup
  | .delivery => Delivery

structure Selection where
  method : Method
  details : Details method
```

The `details` field cannot contain a `Delivery` when `method` is pickup.

The corresponding dependent pair is:

```lean
abbrev PackedSelection := (method : Method) × Details method
```

This is `Sigma Details`. Unlike an ordinary pair, the second component's type depends on the first. A named dependent record is often easier to read in application code. [Dependent pairs](https://lean-lang.org/doc/reference/latest/Basic-Types/Tuples/)

A stage-indexed type takes another form:

```lean
inductive Order : Stage → Type where
  | draft (note : String) : Order .draft
  | ready (amount : Nat) : Order .ready
  | paid (receipt : String) : Order .paid
```

A function accepting `Order .ready` cannot be called with `Order .draft`. This restricts accepted values. Ordinary Lean values can still be reused, so this does not make a payment operation single-use.

**Propositions and proof-related types**

A proposition is a type of evidence. A value of that type is a proof. `Prop` is the universe of propositions; it is not the Boolean type. [Propositions](https://lean-lang.org/doc/reference/latest/The-Type-System/Propositions/)

| Form | Meaning | Useful distinction |
|---|---|---|
| `True`, `False` | A trivially true proposition; a proposition with no proof. | Different from the Boolean values `true` and `false`. |
| `P ∧ Q` / `And P Q` | Evidence for both propositions. | Proof counterpart of pairing. |
| `P ∨ Q` / `Or P Q` | Evidence for at least one proposition. | Use a data sum when the selected branch must be retained as ordinary runtime data. |
| `P → Q` | A proof of `P` can be turned into a proof of `Q`. | Implication is a function type. |
| `¬ P` | A proof of `P` would imply `False`. | States that a case is impossible. |
| `P ↔ Q` | Each proposition implies the other. | Shows that two checks express the same condition. |
| `∀ x : A, P x` | The property holds for every `x`. | Describes guarantees about all inputs. |
| `∃ x : A, P x` / `Exists` | Some witness satisfies the property. | Proves existence; use a Sigma type or subtype when you need the witness as data. |
| `Nonempty A` | There exists a value of `A`. | A proposition, not a supplied default value. |
| `Inhabited A` | A default value of `A` is supplied. | Carries data, rather than merely proving existence. |
| `Subsingleton A` | Any two values of `A` are equal. | Allows zero or one distinct value; does not prove existence. |
| `Decidable P` | A computed yes/no result with evidence supporting the answer. | Connects an executable check to a proof. |

Logical connectives and quantifiers mostly use ordinary inductive definitions in `Prop`; implication and universal quantification use function types. [Logical foundations](https://lean-lang.org/doc/reference/latest/Basic-Propositions/), [quantifiers](https://lean-lang.org/doc/reference/latest/Basic-Propositions/Quantifiers/)

For example:

```lean
def checkQuantity (n : Nat) : Option Quantity :=
  if h : 0 < n ∧ n ≤ 99 then some ⟨n, h⟩ else none
```

The runtime check supplies `h` in the successful branch. That is the evidence needed to construct `Quantity`. Not every proposition comes with an executable decision procedure. [Decidable and type classes](https://lean-lang.org/doc/reference/latest/Type-Classes/)

**Generic and higher-order composition**

These terms describe how types and functions are parameterized. They are not extra state constructors.

| Idea | Example | What it lets us reuse |
|---|---|---|
| Parameterized / generic type | `List A`, `Checkout Input` | One data shape for many element or input types. |
| Polymorphic function | `(A : Type) → A → A` | One implementation for different types. |
| Universe polymorphism | `Box (A : Type u)` | Generic code that also works with types living at higher levels. |
| Higher-order function | `(Item → String) → List Item → List String` | Pass rendering, comparison, or validation behavior as an argument. |
| Higher-rank polymorphism | Accepting an argument of type `(A : Type) → A → A` | Pass a function that must itself remain generic. |
| Higher-kinded parameter | `F : Type → Type` | Abstract over a container or computation constructor such as `List` or `Option`. |
| Type class | `Priced A`, `DecidableEq A` | Request behavior that Lean can supply through instances. |
| Composed instance | `[Priced A] → [Priced B] → Priced (A × B)` conceptually | Build behavior for a larger type from behavior for its parts. |
| Lawful interface | `LawfulFunctor F` | Require proofs that an implementation obeys its stated laws. |

Higher-kinded parameters are ordinary parameters in Lean's type system. A type constructor such as `List` can be passed to a function or class. Type classes provide instance search; they do not add a new primitive type former. [Type classes](https://lean-lang.org/doc/reference/latest/Type-Classes/)

This function works with more than one container:

```lean
def addOneInside {F : Type → Type} [Functor F] (values : F Nat) : F Nat :=
  (fun n => n + 1) <$> values
```

For `some 2`, it returns `some 3`. For `[2, 3]`, it returns `[3, 4]`. `Functor` supplies the operation for mapping over the chosen container. `Applicative` supports combining wrapped computations; `Monad` supports sequencing where later work can depend on earlier results. These are classes over type constructors, not three new primitive kinds of type. [Functor, Applicative, and Monad](https://lean-lang.org/doc/reference/latest/Functors___-Monads-and--do--Notation/)

**Common concrete types and type families**

This is a practical selection from Lean's core and standard library, not an inventory of every declaration. [Basic-types reference](https://lean-lang.org/doc/reference/latest/Basic-Types/)

| Family | Examples | Typical role |
|---|---|---|
| Boolean data | `Bool` | A yes/no value. |
| Exact numbers | `Nat`, `Int`, `Rat` | Counts, signed integers, rational values. |
| Machine numbers | `UInt8`, `UInt32`, `UInt64`, `USize`, `Int32`, `Float`, `Float32` | Interoperability and machine arithmetic. |
| Bounded values | `Fin n` | A natural number strictly below `n`. |
| Bitvectors | `BitVec n` | A fixed number of bits, with the width in the type. |
| Text | `Char`, `String` | Characters and text values. |
| Unit / one-value types | `Unit`, `PUnit` | No meaningful payload is needed. |
| Empty types | `Empty`, `PEmpty` | A case has no possible value. |
| Optional values | `Option A` | A value may be absent. |
| Typed results | `Except Error A` | Either an error payload or a successful value. |
| Sequences | `List A`, `Array A` | Collections of varying size. |
| Fixed-length sequences | `Vector A n` | A sequence with exactly `n` entries. |
| Byte collections | `ByteArray` | Binary data. |
| Maps and sets | `Std.HashMap`, `Std.HashSet`, `Std.TreeMap`, `Std.TreeSet` | Lookup and membership. |
| Dependent maps | `Std.DHashMap Key Value` with `Value : Key → Type` | The value type can depend on the key. |
| Delayed computations | `Thunk A` | A computation whose result is evaluated when demanded. |
| Tasks | `Task A` | A task producing an `A`; distinct from a browser Promise. |
| Effectful computations | `IO A`, `EIO Error A` | Computations interacting with the outside world. |
| State and environment computations | `StateM S A`, `ReaderM R A` | Thread state or read a shared environment. |
| Effect transformers | `StateT`, `ReaderT`, `ExceptT` | Combine state, environment, or error handling with another computation type. |
| Mutable references | `IO.Ref A` | A mutable cell used in IO. |
| Universe wrappers | `ULift A`, `PLift A` | Move values between universe/sort arrangements. |
| Metaprogramming data | `Lean.Name`, `Lean.Syntax`, `Lean.TSyntax kind`, `Lean.Expr` | Represent names, parsed syntax, or elaborated expressions. |

`Fin n`, `BitVec n`, and `Vector A n` are familiar library examples of value-indexed types. `Option` and `Except` are ordinary variants. `Task`, `IO`, and transformers describe computations rather than a new family of domain-state rules. See the [basic types](https://lean-lang.org/doc/reference/latest/Basic-Types/), [IO](https://lean-lang.org/doc/reference/latest/IO/), and [monad reference](https://lean-lang.org/doc/reference/latest/Functors___-Monads-and--do--Notation/).

**Quotients: a different way to reduce distinctions**

A quotient treats equivalent representations as the same value. For example, we could identify natural numbers that have the same final decimal digit. In that quotient, 12 and 22 are equal.

For an application analogy, line-item lists in different orders might represent the same basket. A quotient can express that equivalence, but any function defined on the quotient must respect it. The answer cannot depend on which equivalent list was chosen.

This is useful in proofs and some domain models. It is usually more machinery than a UI needs; a sorted or normalized representation is often easier to use. A quotient does not automatically give an efficient equality test or a canonical representation. [Quotient reference](https://lean-lang.org/doc/reference/latest/The-Type-System/Quotients/)

**Names that are easy to confuse**

| Pair | Difference |
|---|---|
| `Bool` vs `Prop` | `Bool` holds a Boolean value. A proposition describes something for which a proof may exist. |
| `Sigma` vs `Exists` | A Sigma pair packages a witness as data. `Exists` proves that a witness exists; it does not generally let runtime code extract that witness. |
| `Sigma` vs `Subtype` | Sigma's second part is dependent data. A subtype's second part is proof that its first part satisfies a condition. |
| `Unit` vs `True` | `Unit` is a data type with one value. `True` is a proposition. |
| `Empty` vs `False` | Both are uninhabited, but one is a data type and one is a proposition. |
| `Inhabited A` vs `Nonempty A` | `Inhabited` supplies a default value. `Nonempty` only states existence. |
| `BEq A` vs `DecidableEq A` | `BEq` supplies a Boolean comparison. `DecidableEq` decides Lean's equality proposition and supplies evidence. A bare `BEq` instance need not agree with equality. |
| Type class vs ordinary record | Both can carry operations. Classes additionally participate in automatic instance search. |
| Type alias vs distinct wrapper | `abbrev UserId := Nat` is still `Nat`. `structure UserId where value : Nat` creates a distinct type. |
| Parameter vs index | A parameter is uniform across an inductive type's constructors; constructors can determine different indices. |
| `Subtype` vs object-oriented subtyping | A subtype expresses a predicate on values. It is not a general inheritance hierarchy. |
| Sum vs an untagged union | `A ⊕ B` retains an explicit left/right choice. It is not an arbitrary TypeScript-style union of overlapping object shapes. |

The data/proof distinctions follow Lean's rules for [propositions](https://lean-lang.org/doc/reference/latest/The-Type-System/Propositions/), [quantifiers](https://lean-lang.org/doc/reference/latest/Basic-Propositions/Quantifiers/), and [dependent pairs](https://lean-lang.org/doc/reference/latest/Basic-Types/Tuples/). Equality-related classes are covered under [basic classes](https://lean-lang.org/doc/reference/latest/Type-Classes/Basic-Classes/).

Aliases (`abbrev`), coercions, private constructors, and opacity are useful abstraction tools. They are not additional data shapes. A coercion asks Lean to insert a declared conversion. A private constructor restricts where values can be built. An opaque declaration hides an implementation from definitional reduction.

**Which ones help with state explosion?**

There are two different goals: restrict the combinations an application can represent, and reuse code across the combinations it should support.

| Technique | Main contribution |
|---|---|
| Sums / variants | Keep mutually exclusive cases separate. |
| Dependent records, Sigma types, indexed families | Keep related values aligned. |
| Subtypes and proof fields | Require relationships or bounds to hold. |
| Products / records | Compose independent pieces; their real combinations remain. |
| Generics and higher-order functions | Reuse structure and behavior across types. |
| Type classes and composed instances | Assemble behavior from smaller implementations. |
| Quotients | Identify representations judged equivalent. |
| Recursive types | Express recursive structure without choosing an arbitrary maximum depth. They do not make the number of possible values smaller. |

For finite types, the arithmetic makes the difference clear:

| Construction | Number of values |
|---|---|
| `A × B` | `size(A) × size(B)` |
| `A ⊕ B` | `size(A) + size(B)` |
| `A → B` | `size(B) ^ size(A)` |
| `(a : A) × B a` | Sum `size(B a)` over all `a`. |
| `(a : A) → B a` | Multiply `size(B a)` over all `a`. |
| `{ a : A // P a }` | Count the values of `A` satisfying `P`. Proofs do not multiply the choices. |
| Quotient by an equivalence relation | Count its equivalence classes. |

These count mathematical values, not source-code expressions or execution histories. Type classes do not have a comparable automatic state-reduction formula.

For the checkout post, the most useful sequence is: products and sums; a generic lifecycle; a quote indexed by its request; checked input values; then composed type-class instances. Sigma types and computed families are good follow-ups when one form's fields depend on an earlier selection.

The larger worked example is in [checkout_story.md](checkout_story.md), with its executable model in [Checkout.lean](Checkout.lean).
