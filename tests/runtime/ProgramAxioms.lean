/- Axiom audit of the component theorems (P5): each uses no `sorry` and no axiom beyond Lean's
three (`propext`, `Classical.choice`, `Quot.sound`). -/
import Examples.ProgramProofs
open Lean

run_meta do
  let theorems := [`Examples.ProgramProofs.bounded_counter_capped, `Examples.ProgramProofs.Capped.preserved_cappedUpdate,
    `Examples.ProgramProofs.todos_ok, `Examples.ProgramProofs.TodoOk.preserved_todoUpdate,
    `Examples.ProgramProofs.empty_draft_adds_nothing, `Examples.ProgramProofs.reset_disabled_iff_zero,
    `Examples.ProgramProofs.add_disabled_iff_empty]
  for name in theorems do
    let axioms ← collectAxioms name
    let extra := axioms.filter fun a => ![``propext, ``Classical.choice, ``Quot.sound].contains a
    unless extra.isEmpty do throwError "{name} depends on {extra}"
  logInfo m!"Component theorems: {theorems.length} pass the axiom audit"
