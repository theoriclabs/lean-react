# Choosing a model for related state

These guides are for programmers who already know records, functions, and frontend state. Start with the bug or relationship you need to express. You do not need every technique in one application.

Each guide explains the model, when it pays off, when a simpler approach is enough, how edits and runtime input work, and what to check. The accompanying examples target Lean 4.33.0. They establish properties of Lean models; they do not claim that every example has been compiled to a browser or integrated with a backend.

| What you are noticing | Start here | A simpler first step |
|---|---|---|
| Fields apply only in one mode. | [1. Conditional structure](01-conditional-structure.md) | Use one tagged variant for the selected mode. |
| One selection changes the options for another. | [2. Dependent choices](02-dependent-choices.md) | Filter options and validate the pair in one function. |
| Results from different requests get mixed together. | [3. A shared context](03-shared-context.md) | Keep a complete request key and generation with each result. |
| Fields are valid individually but wrong together. | [4. Rules on combinations](04-relational-refinements.md) | Add one validator for the whole record. |
| Several checks may concern different versions of a value. | [5. Several rules on one value](05-combined-predicates.md) | Pass one immutable snapshot to every check. |
| Counts, selections, or membership get out of sync. | [6. Dependent collections](06-dependent-collections.md) | Derive selections from stable keys and validate at submission. |
| Form definitions and accepted data shapes drift apart. | [7. Schemas that compute types](07-schema-interpreters.md) | Use a small explicit variant before designing a schema language. |
| Form validation is repeatedly rebuilt for compound values. | [8. Composed validation contracts](08-composed-validation.md) | Compose explicit parser values first. |
| Changing an earlier choice invalidates several later choices. | [9. Chains of context](09-context-chains.md) | Reset downstream state in one reducer. |
| Only some combinations of integrations and options work. | [10. Compatibility constraints](10-compatibility.md) | Put the support matrix in one checked function. |
| Workflow steps are called in the wrong order. | [11. Indexed transitions](11-indexed-transitions.md) | Start with a state enum and a transition function. |
| A total, flag, or cached result disagrees with its inputs. | [12. Derived state](12-derived-state.md) | Compute it instead of storing it. |
| Several representations mean the same domain value. | [13. Equivalent representations](13-equivalent-representations.md) | Normalize at the boundary. |

**How to decide whether stronger types are worth it**

Write the relationship in one sentence: “this quote belongs to this request,” or “the end follows the start.” Identify the places where it is established, the places where it can be invalidated, and the functions that rely on it. Stronger types pay off when that relationship crosses component or module boundaries, survives async work, or gets checked repeatedly.

If the relationship is local, cheap to derive, and used once, a function may be enough. If it belongs to the accepted domain value, a checked constructor and subtype are often the next step. Reach for indexed families when later types or operations really depend on earlier values. Reach for type classes when the implementations themselves repeat and have a useful, predictable default.

Changing a type does not discover missing business rules. Decide which relationship matters before encoding it. Drafts also need room for incomplete input. A smaller accepted-value space does not mean that every intermediate keystroke must be valid.

**How the guides fit together**

Checkout can start with a pickup/delivery variant, use a country-dependent service choice, validate the resulting address/service pair, and keep the quote tied to a request snapshot. A later authorization can depend on the exact quote. Each piece solves a different problem.

Products combine independent pieces. Refinements add rules on their combination. Dependent fields connect their identities or shapes. Generic code and type-class instances then reuse operations over these combined types. The [focused catalog](../state_space_composition.md) explains this composition, while the [broader catalog](../type_catalog.md) defines the terminology.

**Checking the examples**

Run these from the repository root:

```sh
lake env lean docs/blog/workshop/guides/GuideExamples.lean
lake env lean docs/blog/workshop/StateSpaceComposition.lean
lake env lean docs/blog/workshop/Checkout.lean
```

`#guard` checks behavior and finite counts. `#check_failure` checks that an invalid expression is rejected; its expected diagnostics can appear in a successful run. These examples are teaching models. The guide text calls out what each one proves and what a production boundary would still need to establish.

The examples use a few recurring notations: `A × B` means both values, `A ⊕ B` means one alternative, `{ x : A // P x }` means a value satisfying a predicate, and `T value` can be a type indexed by that value. Square brackets such as `[Editor A]` ask Lean to supply a type-class instance.
