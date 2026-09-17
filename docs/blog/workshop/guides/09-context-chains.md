# Make later choices depend on the exact earlier choices

[All guides](README.md) · Checked examples: `Chains` in [GuideExamples.lean](GuideExamples.lean), `ReadyChain` in [StateSpaceComposition.lean](../StateSpaceComposition.lean)

A patient chooses a clinic, a clinician, and an appointment slot. Then they change the clinician. The slot stays selected, even though it belonged to someone else.

All the choices might belong to the same clinic. That is not enough. The slot must belong to the selected clinician, and a reservation must belong to the selected slot.

**The model**

```lean
structure Appointment where
  clinic : Clinic
  clinician : Clinician clinic
  slot : Slot clinician
  reservation : Reservation slot
```

Each field can refer to an earlier field. The type forms a chain: clinic → clinician → slot → reservation. The source defines the four indexed structures and builds a complete appointment.

A record with dependent fields is convenient syntax for packaging these relationships together. Nested dependent pairs can express the same pattern. [Dependent pairs in Lean](https://lean-lang.org/doc/reference/latest/Basic-Types/Tuples/)

The example rejects replacing Alice with Bob while retaining Alice's slot. The types disagree at the exact link where the old choice became invalid.

**Use this when**

Use it for cascading selections, resource hierarchies, and results that belong to a particular earlier result. Examples include an organization, repository, and branch; an account, document, and revision; or a request, quote, and authorization.

Choose a shared context when every artifact only needs to agree on the same snapshot. A chain is useful when that guarantee is too weak. In checkout, two quotes can belong to one request while quoting different amounts. An authorization tied to the exact quote rules out mixing those two results.

Choose a reducer that clears dependent fields if the whole workflow is small and local. The indexed model becomes more useful when several modules assemble or consume the completed chain.

**Model incomplete progress separately**

The user does not begin with a complete `Appointment`. The draft may have a clinic and no clinician yet. It may have a clinician while slots are loading.

Give those stages their own cases, or keep an explicit draft with optional selections. Construct the completed appointment only after the required choices and reservation are available. The complete type is the contract for a completed operation, not a demand that the form invent a slot on first render.

On an earlier edit, reconsider the descendants:

1. Keep choices before the changed field.
2. Clear or revalidate choices after it.
3. Start dependent requests using the new context.
4. Accept responses only for that context.

You can preserve old selections as drafts for convenience. To reuse one as an accepted choice, resolve it against the new parent. A matching display label is not sufficient evidence.

**Be deliberate about identity**

The example's `Clinic` includes a revision. A real application must decide what makes a clinician or slot the same: a stable ID, a schedule version, or the full immutable request. Indexing on a frequently edited display name would create unnecessary invalidations. Indexing on too little data can leave important differences invisible.

The example's constructors are public and its reservation reference is demo data. The types preserve associations after construction; they do not establish that a backend offered the slot or accepted the reservation. Put that responsibility in the producer or decoder.

**Compose it further**

Use [shared request context](03-shared-context.md) for async responses at each stage. Use [relational refinements](04-relational-refinements.md) for additional rules, such as a slot falling inside a permitted booking window. Use [indexed transitions](11-indexed-transitions.md) when the order of operations also needs a contract.

Check changing every upstream field, responses arriving after that change, a different parent with identical-looking children, and reservation failure. A correct completed chain should remain impossible to assemble from stale descendants.
