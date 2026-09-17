# Compose workflow steps in an allowed order

[All guides](README.md) · Checked example: `Step` and `Path` in [StateSpaceComposition.lean](../StateSpaceComposition.lean)

An order should be quoted before it is authorized. A plain list of action names can describe authorization first, or authorization twice. Every runner then has to interpret and reject those sequences.

Give each step a starting phase and an ending phase. Composition can require the phases to line up.

**The model**

```lean
inductive Phase where
  | editing | quoted | authorized

inductive Step : Phase → Phase → Type where
  | quote : Step .editing .quoted
  | authorize : Step .quoted .authorized

inductive Path : Phase → Phase → Type where
  | done : Path phase phase
  | next : Step first middle → Path middle last → Path first last
```

`Step .editing .quoted` describes a step that starts in editing and ends in quoted. `Path.next` joins a step to the rest of a path only when their shared `middle` phase matches.

```lean
def checkoutPath : Path .editing .authorized :=
  .next .quote (.next .authorize .done)
```

Starting that path with `authorize` is rejected. Its first phase is `quoted`, but the path promises to start in `editing`. This is an indexed inductive type: constructors select which indices their values can have. [Indexed families in Lean](https://lean-lang.org/functional_programming_in_lean/Programming-with-Dependent-Types/Indexed-Families/)

**Use this when**

Use it when code assembles workflows, protocols, or reusable sequences of operations. It is helpful when functions accept states at particular phases and return states at new phases. A library can expose legal steps without exposing an unrestricted “set phase” operation.

Choose an enum and a reducer for a small interactive flow. That is often enough to centralize allowed transitions. Introduce indices when reusable step composition or phase-specific APIs are becoming hard to maintain.

This pattern mainly reduces allowed programs and transition sequences. It does not necessarily reduce the number of stored screen states.

**Connect descriptions to real behavior**

The example constructs a path description. It does not fetch a quote, authorize money, or execute the path. A runner would need to interpret each step and handle its results.

A real quote operation can fail. Its result should express that: success produces a quoted state, while failure produces an error or a state from which retry is allowed. Do not claim that every effect reaches its intended ending phase merely because the happy-path description does.

If a quote must belong to the current cart, attach the [request context](03-shared-context.md) as well. A phase label by itself says nothing about the quote's ownership or amount.

**Handle runtime phases explicitly**

A React component discovers its current phase at runtime. It can store a variant whose cases contain the corresponding phase-specific data. Another approach is a dependent pair containing a phase and a value indexed by that phase. Either way, dispatch by matching on the current phase before calling a phase-specific operation.

Begin with one transition that matters. Make its input and output contracts explicit. Then add composition. There is little value in indexing every UI gesture if only one operation depends on the phase.

**What this does not guarantee**

Lean values can generally be reused. Holding an authorized value does not automatically mean it can be consumed only once. Preventing double submission still needs an appropriate controller and, for an external transaction, backend idempotency or another server-side guarantee.

Cancellation, retries, and rollback also need explicit semantics. Type-correct sequencing does not make several network calls atomic.

Check an accepted sequence, a reversed sequence, skipped steps, and failure or retry from each stage. If you build a runner, check that its behavior matches the path contract. The current source checks composition and rejects a path that starts with authorization.
