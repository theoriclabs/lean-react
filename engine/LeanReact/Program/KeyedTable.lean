import LeanReact.Program.Elements
import LeanJS.StackSafe

/-! # Keyed relational tables for UI state

A flat, `Type 0` keyed table `KeyedTable Id Row` for declarative component models:
instead of ad-hoc `List` CRUD with per-app `Nodup` induction proofs, state lives in a
keyed table whose `upsert`, `modify`, `erase`, `ofList` and `reconcile` operations preserve
`UniqueKeys` (`keys.Nodup`) once and for all. -/

namespace LeanReact.Program

/-- A relational table keyed by `Id`. -/
structure KeyedTable (Id Row : Type) where
  entries : List (Id × Row) := []
  deriving Repr, BEq, DecidableEq

namespace KeyedTable

/-- An empty keyed table. -/
def empty {Id Row : Type} : KeyedTable Id Row := ⟨[]⟩

instance {Id Row : Type} : EmptyCollection (KeyedTable Id Row) := ⟨empty⟩
instance {Id Row : Type} : Inhabited (KeyedTable Id Row) := ⟨empty⟩

/-- Keys in row order. -/
def keys {Id Row : Type} (table : KeyedTable Id Row) : List Id :=
  table.entries.map Prod.fst

/-- Rows in table order. -/
def values {Id Row : Type} (table : KeyedTable Id Row) : List Row :=
  table.entries.map Prod.snd

/-- Number of rows stored. -/
def size {Id Row : Type} (table : KeyedTable Id Row) : Nat :=
  table.entries.length

/-- No key appears twice in the table. -/
def UniqueKeys {Id Row : Type} (table : KeyedTable Id Row) : Prop :=
  table.keys.Nodup

/-- Decidable runtime check matching `UniqueKeys` when `Id` has `DecidableEq`. -/
def checkUniqueKeys {Id Row : Type} [DecidableEq Id] (table : KeyedTable Id Row) : Bool :=
  table.keys.Nodup

/-- Look up the first row stored for `id`. -/
def find? {Id Row : Type} [BEq Id] (table : KeyedTable Id Row) (id : Id) : Option Row :=
  match table.entries.find? (fun entry => entry.1 == id) with
  | some entry => some entry.2
  | none => none

/-- Whether `id` is present in `table`. -/
def contains {Id Row : Type} [BEq Id] (table : KeyedTable Id Row) (id : Id) : Bool :=
  (table.find? id).isSome

@[leanjs_stack_safe] private def upsertEntries {Id Row : Type} [BEq Id]
    (id : Id) (row : Row) : List (Id × Row) → List (Id × Row)
  | [] => [(id, row)]
  | (k, v) :: rest =>
    if k == id then (id, row) :: rest
    else (k, v) :: upsertEntries id row rest

/-- Insert `row` at `id`, or replace the existing row for `id` in place. -/
def upsert {Id Row : Type} [BEq Id] (table : KeyedTable Id Row) (id : Id) (row : Row) :
    KeyedTable Id Row :=
  ⟨upsertEntries id row table.entries⟩

@[leanjs_stack_safe] private def modifyEntries {Id Row : Type} [BEq Id]
    (id : Id) (f : Row → Row) : List (Id × Row) → List (Id × Row)
  | [] => []
  | (k, v) :: rest =>
    if k == id then (k, f v) :: rest
    else (k, v) :: modifyEntries id f rest

/-- Update the row stored at `id` in place when present. -/
def modify {Id Row : Type} [BEq Id] (table : KeyedTable Id Row) (id : Id) (f : Row → Row) :
    KeyedTable Id Row :=
  ⟨modifyEntries id f table.entries⟩

@[leanjs_stack_safe] private def eraseEntries {Id Row : Type} [BEq Id]
    (id : Id) : List (Id × Row) → List (Id × Row)
  | [] => []
  | (k, v) :: rest =>
    if k == id then eraseEntries id rest
    else (k, v) :: eraseEntries id rest

/-- Remove any entry keyed by `id`. -/
def erase {Id Row : Type} [BEq Id] (table : KeyedTable Id Row) (id : Id) : KeyedTable Id Row :=
  ⟨eraseEntries id table.entries⟩

/-- Build a deduplicated table from `rows`, later entries winning in place/order. -/
def ofList {Id Row : Type} [BEq Id] (rows : List (Id × Row)) : KeyedTable Id Row :=
  rows.foldl (fun table entry => table.upsert entry.1 entry.2) empty

/-- Index plain rows by `key`, preserving `UniqueKeys`. -/
def ofRows {Id Row : Type} [BEq Id] (key : Row → Id) (rows : List Row) : KeyedTable Id Row :=
  rows.foldl (fun table row => table.upsert (key row) row) empty

/-- Reconcile a fresh server snapshot with pending optimistic updates so duplicate keys
cannot appear and optimistic edits override matching server rows. -/
def reconcile {Id Row : Type} [BEq Id]
    (server : List (Id × Row)) (optimistic : List (Id × Row)) : KeyedTable Id Row :=
  optimistic.foldl (fun table entry => table.upsert entry.1 entry.2) (ofList server)

/-- Render all rows with React keys derived from `Id`. -/
def view {Id Row Msg : Type} (table : KeyedTable Id Row)
    (key : Id → String) (render : Id → Row → Html Msg)
    (attrs : List (Attr Msg) := []) (tag : String := "div") : Html Msg :=
  each table.entries (fun entry => key entry.1) (fun entry => render entry.1 entry.2) attrs tag

/-! ## Built-in uniqueness and lookup invariants -/

private theorem mem_keys_upsertEntries {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {k id : Id} {row : Row} {xs : List (Id × Row)} :
    k ∈ (upsertEntries id row xs).map Prod.fst → k = id ∨ k ∈ xs.map Prod.fst := by
  induction xs with
  | nil =>
    simp [upsertEntries]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [upsertEntries]
    split
    · case isTrue h =>
      have hk : k' = id := eq_of_beq h
      intro hkmem
      simp only [List.map_cons, List.mem_cons] at hkmem ⊢
      rcases hkmem with rfl | hkmem
      · exact Or.inl rfl
      · exact Or.inr (Or.inr hkmem)
    · case isFalse _ =>
      intro hkmem
      simp only [List.map_cons, List.mem_cons] at hkmem ⊢
      rcases hkmem with rfl | hkmem
      · exact Or.inr (Or.inl rfl)
      · rcases ih hkmem with rfl | htl
        · exact Or.inl rfl
        · exact Or.inr (Or.inr htl)

private theorem nodup_keys_upsertEntries {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {id : Id} {row : Row} {xs : List (Id × Row)}
    (h : (xs.map Prod.fst).Nodup) :
    ((upsertEntries id row xs).map Prod.fst).Nodup := by
  induction xs with
  | nil =>
    simp [upsertEntries]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [upsertEntries]
    simp only [List.map_cons, List.nodup_cons] at h
    rcases h with ⟨hk'_not_mem, htl⟩
    split
    · case isTrue heq =>
      have hk : k' = id := eq_of_beq heq
      subst hk
      simp only [List.map_cons, List.nodup_cons]
      exact ⟨hk'_not_mem, htl⟩
    · case isFalse hne =>
      have hk_ne_id : k' ≠ id := fun heq => hne (beq_iff_eq.mpr heq)
      simp only [List.map_cons, List.nodup_cons]
      refine ⟨?_, ih htl⟩
      intro hk_mem
      rcases mem_keys_upsertEntries hk_mem with rfl | hk_in_tl
      · exact hk_ne_id rfl
      · exact hk'_not_mem hk_in_tl

private theorem keys_modifyEntries {Id Row : Type} [BEq Id]
    (id : Id) (f : Row → Row) (xs : List (Id × Row)) :
    (modifyEntries id f xs).map Prod.fst = xs.map Prod.fst := by
  induction xs with
  | nil => rfl
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [modifyEntries]
    split <;> simp [ih]

private theorem mem_keys_eraseEntries {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {k id : Id} {xs : List (Id × Row)} :
    k ∈ (eraseEntries id xs).map Prod.fst → k ∈ xs.map Prod.fst ∧ k ≠ id := by
  induction xs with
  | nil =>
    simp [eraseEntries]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [eraseEntries]
    split
    · case isTrue heq =>
      intro hk
      rcases ih hk with ⟨htl, hne⟩
      exact ⟨by simp [htl], hne⟩
    · case isFalse hne =>
      intro hk
      simp only [List.map_cons, List.mem_cons] at hk
      rcases hk with rfl | htl
      · exact ⟨by simp, fun h => hne (beq_iff_eq.mpr h)⟩
      · rcases ih htl with ⟨hmem, hne'⟩
        exact ⟨by simp [hmem], hne'⟩

private theorem nodup_keys_eraseEntries {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {id : Id} {xs : List (Id × Row)} (h : (xs.map Prod.fst).Nodup) :
    ((eraseEntries id xs).map Prod.fst).Nodup := by
  induction xs with
  | nil =>
    simp [eraseEntries]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [List.map_cons, List.nodup_cons] at h
    rcases h with ⟨hk'_not_mem, htl⟩
    simp only [eraseEntries]
    split
    · exact ih htl
    · simp only [List.map_cons, List.nodup_cons]
      refine ⟨?_, ih htl⟩
      intro hk_mem
      exact hk'_not_mem (mem_keys_eraseEntries hk_mem).1

theorem empty_uniqueKeys {Id Row : Type} : (empty : KeyedTable Id Row).UniqueKeys := by
  simp [UniqueKeys, empty, keys]

theorem upsert_uniqueKeys {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {table : KeyedTable Id Row} (h : table.UniqueKeys) (id : Id) (row : Row) :
    (table.upsert id row).UniqueKeys :=
  nodup_keys_upsertEntries h

theorem modify_uniqueKeys {Id Row : Type} [BEq Id]
    {table : KeyedTable Id Row} (h : table.UniqueKeys) (id : Id) (f : Row → Row) :
    (table.modify id f).UniqueKeys := by
  simpa [UniqueKeys, modify, keys, keys_modifyEntries] using h

theorem erase_uniqueKeys {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {table : KeyedTable Id Row} (h : table.UniqueKeys) (id : Id) :
    (table.erase id).UniqueKeys :=
  nodup_keys_eraseEntries h

private theorem foldl_upsert_uniqueKeys {Id Row α : Type} [BEq Id] [LawfulBEq Id]
    (key : α → Id) (val : α → Row) (xs : List α) (init : KeyedTable Id Row)
    (h : init.UniqueKeys) :
    (xs.foldl (fun t x => t.upsert (key x) (val x)) init).UniqueKeys := by
  induction xs generalizing init with
  | nil => exact h
  | cons x xs ih => exact ih _ (upsert_uniqueKeys h (key x) (val x))

theorem ofList_uniqueKeys {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (rows : List (Id × Row)) : (ofList rows).UniqueKeys :=
  foldl_upsert_uniqueKeys Prod.fst Prod.snd rows empty empty_uniqueKeys

theorem ofRows_uniqueKeys {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (key : Row → Id) (rows : List Row) : (ofRows key rows).UniqueKeys :=
  foldl_upsert_uniqueKeys key id rows empty empty_uniqueKeys

theorem reconcile_uniqueKeys {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (server optimistic : List (Id × Row)) : (reconcile server optimistic).UniqueKeys :=
  foldl_upsert_uniqueKeys Prod.fst Prod.snd optimistic (ofList server) (ofList_uniqueKeys server)

private theorem list_find?_upsertEntries_self {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (id : Id) (row : Row) (xs : List (Id × Row)) :
    (upsertEntries id row xs).find? (fun e => e.1 == id) = some (id, row) := by
  induction xs with
  | nil =>
    simp [upsertEntries]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [upsertEntries]
    split
    · case isTrue h =>
      simp [List.find?]
    · case isFalse h =>
      simp only [List.find?, h]
      exact ih

private theorem list_find?_upsertEntries_ne {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {k target : Id} (hne : k ≠ target) (row : Row) (xs : List (Id × Row)) :
    (upsertEntries target row xs).find? (fun e => e.1 == k) = xs.find? (fun e => e.1 == k) := by
  induction xs with
  | nil =>
    have hkt : (target == k) = false := beq_false_of_ne hne.symm
    simp [upsertEntries, List.find?, hkt]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [upsertEntries]
    split
    · case isTrue heq =>
      have hk' : k' = target := eq_of_beq heq
      subst hk'
      have hkt : (k' == k) = false := beq_false_of_ne hne.symm
      simp [List.find?, hkt]
    · case isFalse _ =>
      simp only [List.find?]
      by_cases hk : (k' == k) = true <;> simp [hk, ih]

theorem find?_upsert_self {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (table : KeyedTable Id Row) (id : Id) (row : Row) :
    (table.upsert id row).find? id = some row := by
  simp [find?, upsert, list_find?_upsertEntries_self]

theorem find?_upsert_ne {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (table : KeyedTable Id Row) {k id : Id} (hne : k ≠ id) (row : Row) :
    (table.upsert id row).find? k = table.find? k := by
  simp [find?, upsert, list_find?_upsertEntries_ne hne]

private theorem list_find?_eraseEntries_self {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (target : Id) (xs : List (Id × Row)) :
    (eraseEntries target xs).find? (fun e => e.1 == target) = none := by
  induction xs with
  | nil => simp [eraseEntries]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [eraseEntries]
    split
    · exact ih
    · case isFalse h => simp [List.find?, h, ih]

private theorem list_find?_eraseEntries_ne {Id Row : Type} [BEq Id] [LawfulBEq Id]
    {k target : Id} (hne : k ≠ target) (xs : List (Id × Row)) :
    (eraseEntries target xs).find? (fun e => e.1 == k) = xs.find? (fun e => e.1 == k) := by
  induction xs with
  | nil => simp [eraseEntries, List.find?]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [eraseEntries]
    split
    · case isTrue heq =>
      have hk' : k' = target := eq_of_beq heq
      subst hk'
      have hkt : (k' == k) = false := beq_false_of_ne hne.symm
      simp [List.find?, hkt, ih]
    · case isFalse _ =>
      simp only [List.find?]
      by_cases hk : (k' == k) = true <;> simp [hk, ih]

theorem find?_erase_self {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (table : KeyedTable Id Row) (id : Id) :
    (table.erase id).find? id = none := by
  simp [find?, erase, list_find?_eraseEntries_self]

theorem find?_erase_ne {Id Row : Type} [BEq Id] [LawfulBEq Id]
    (table : KeyedTable Id Row) {k id : Id} (hne : k ≠ id) :
    (table.erase id).find? k = table.find? k := by
  simp [find?, erase, list_find?_eraseEntries_ne hne]

end KeyedTable
end LeanReact.Program
