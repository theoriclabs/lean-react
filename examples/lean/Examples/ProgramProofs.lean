import Examples.Program

/-! Proofs about declarative components (P5): invariants of `update` through LeanAPI's property
kernel, and theorems about the pure `view`. `tests/runtime/ProgramAxioms.lean` audits them: no
`sorry`, no axiom beyond Lean's three. -/

namespace Examples.ProgramProofs
open LeanReact.Program LeanApi.Props Examples.Program

/-! ## A bounded counter -/

/-- Adding past 99 stops at 99. -/
def cappedUpdate : CounterMsg → Nat → Nat × Cmd CounterMsg
  | .add k, n => if n + k ≤ 99 then (n + k, .none) else (99, .none)
  | .reset, _ => (0, .none)

def BoundedCounter : Component Unit Nat CounterMsg where
  init _ := (0, .none)
  update _ := cappedUpdate
  view _ n := Counter.view n n

invariant Capped (n : Nat) where
  le : n ≤ 99

preserves Capped by cappedUpdate

/-- Theorem 1: the count never exceeds 99, in every reachable state. -/
theorem bounded_counter_capped : Invariant (BoundedCounter.toSys ()) (fun (n : Nat) => n ≤ 99) :=
  BoundedCounter.invariant_of () (by decide) fun msg n h =>
    (Capped.preserved_cappedUpdate msg n _ _ ⟨h⟩ rfl).le

/-! ## The todo list -/

/-- Rows are keyed by id: every id is below `nextId` and no two are equal; no title is empty. -/
private theorem nodup_reverse {l : List Nat} (h : l.Nodup) : l.reverse.Nodup :=
  List.pairwise_reverse.mpr (h.imp fun hab => Ne.symm hab)

invariant TodoOk (m : TodoModel) where
  fresh : ∀ t ∈ m.todos, t.id < m.nextId
  distinct : (m.todos.map (·.id)).Nodup
  titled : ∀ t ∈ m.todos, t.title ≠ ""

preserves TodoOk by todoUpdate
  | todoUpdate =>
    all_goals first
      | (rw [List.map_reverse]; exact nodup_reverse hI.distinct)
      | (simp only [List.map_map, Function.comp_def, apply_ite (f := Todo.id), ite_self]; exact hI.distinct)
      | (intro t ht
         simp only [List.mem_map] at ht
         obtain ⟨u, hu, rfl⟩ := ht
         split <;> simp [hI.fresh u hu, hI.titled u hu])
      | (intro t ht
         simp only [List.mem_append, List.mem_singleton] at ht
         rcases ht with ht | rfl
         · have := hI.fresh t ht; omega
         · simp)
      | (intro t ht
         simp only [List.mem_append, List.mem_singleton] at ht
         rcases ht with ht | rfl
         · exact hI.titled t ht
         · simpa [String.isEmpty_iff] using c1)
      | (rw [List.map_append, List.nodup_append]
         refine ⟨hI.distinct, by simp, ?_⟩
         intro a ha b hb
         simp only [List.mem_map, List.mem_singleton] at ha hb
         obtain ⟨u, hu, rfl⟩ := ha
         obtain ⟨_, rfl, rfl⟩ := hb
         have := hI.fresh u hu
         simp only [ne_eq]
         omega)

/-- Theorem 2: in every reachable state the rows are keyed by distinct ids (each below
`nextId`), and no todo has an empty title. -/
theorem todos_ok : Invariant (Todos.toSys ()) TodoOk :=
  Todos.invariant_of () (by decide) fun msg m h => TodoOk.preserved_todoUpdate msg m _ _ h rfl

/-- Theorem 3: submitting an empty draft never adds a todo (an invalid form emits nothing). -/
theorem empty_draft_adds_nothing (m : TodoModel) (h : m.draft = "") : (todoUpdate .add m).1 = m := by
  simp [todoUpdate, h]

/-! ## Theorems about views -/

/-- Theorem 4: the Reset button is disabled exactly when the count is 0. -/
theorem reset_disabled_iff_zero (start n : Nat) :
    ((Counter.view start n).attrsOf "button" "Reset").map Attr.disabledIn = some (n == 0) := by
  simp [Counter, Html.attrsOf, Html.attrsOfList, directText, Attr.disabledIn, div, p, button, text,
    cls, role, onClick, disabled]

/-- Theorem 5: the todo form's Add button is disabled exactly when the draft is empty. -/
theorem add_disabled_iff_empty (m : TodoModel) :
    ((todoView m).attrsOf "button" "Add").map Attr.disabledIn = some m.draft.isEmpty := by
  simp [todoView, Html.attrsOf, Html.attrsOfList, directText, Attr.disabledIn, section_, form, input,
    button, text, ariaLabel, value, onInput, onKeyDown, type_, disabled, onSubmit]

end Examples.ProgramProofs
