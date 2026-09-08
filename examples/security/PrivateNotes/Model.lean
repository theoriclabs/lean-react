import PrivateNotes.Spec

namespace PrivateNotes

/-- Checked session evidence, indexed by an abstract request scope and exact facts/caller.
No JSON decoder. Host code must supply facts from the authenticated transaction. -/
structure ReadGrant (τ : Type) (s : SessionFacts) (p : Principal) : Type where
  private mk ::
  valid : SessionValid s p

variable {τ : Type} {snapshot : Snapshot} {p : Principal} {s : SessionFacts}

def authorize (τ : Type) (s : SessionFacts) (p : Principal) :
    Except String (ReadGrant τ s p) :=
  if h : SessionValid s p then .ok ⟨h⟩ else .error "auth.required"

/-- Executable query predicate. The theorem below refers to the separate specification. -/
def ownedPredicate (p : Principal) (n : Note) : Bool :=
  n.owner == p.actor && n.tenant == p.tenant

theorem ownedPredicate_sound (p : Principal) (n : Note)
    (h : ownedPredicate p n = true) : Owned p n := by
  simpa [ownedPredicate, Owned] using h

theorem ownedPredicate_exact (p : Principal) (n : Note) :
    ownedPredicate p n = true ↔ Owned p n := by
  simp [ownedPredicate, Owned]

/-- Stable ordering is applied to the scoped relation, never to an unscoped page. -/
def visible (p : Principal) (notes : List Note) : List Note :=
  (notes.filter (ownedPredicate p)).mergeSort (fun a b => a.id ≤ b.id)

theorem visible_sound {p : Principal} {notes : List Note} {n : Note}
    (h : n ∈ visible p notes) : n ∈ notes ∧ Owned p n := by
  simpa [visible, ownedPredicate, Owned] using h

theorem visible_exact {p : Principal} {notes : List Note} {n : Note} :
    n ∈ visible p notes ↔ n ∈ notes ∧ Owned p n := by
  simp [visible, ownedPredicate, Owned]

structure Criteria where
  search : String := ""
  id : Option Nat := none
  offset : Nat := 0
  limit : Nat := 50
  deriving BEq, Repr

def selectedBy (c : Criteria) (n : Note) : Bool :=
  n.title.contains c.search && (c.id.isNone || c.id == some n.id)

def matching (rows : List Note) (c : Criteria) : List Note := rows.filter (selectedBy c)

def page (rows : List Note) (c : Criteria) : List Note :=
  ((matching rows c).drop c.offset).take (min c.limit 100)

theorem page_subset {rows : List Note} {c : Criteria} {n : Note}
    (h : n ∈ page rows c) : n ∈ rows := by
  have h := List.mem_of_mem_take h
  have h := List.mem_of_mem_drop h
  exact (List.mem_filter.mp h).1

structure CertifiedNotes (τ : Type) (s : SessionFacts) (p : Principal) where
  private mk ::
  rows : List Note
  authorized : ∀ n ∈ rows, CanRead s p n

/-- Defense at the decoded native-row boundary. Reject the entire result on mismatch.
This checks ownership, not SQLite/decoder fidelity or result completeness. -/
def certify (grant : ReadGrant τ s p) (rows : List Note) :
    Except String (CertifiedNotes τ s p) :=
  if h : ∀ n ∈ rows, Owned p n then
    .ok ⟨rows, fun n hn => ⟨grant.valid, h n hn⟩⟩
  else .error "notes.adapter_scope_violation"

/-- Pure protected repository. A grant is mandatory; no IO capability is exposed. -/
def read (grant : ReadGrant τ snapshot.session p) (c : Criteria) :
    CertifiedNotes τ snapshot.session p :=
  ⟨page (visible p snapshot.notes) c, fun _ h =>
    ⟨grant.valid, (visible_sound (page_subset h)).2⟩⟩

theorem read_sound (grant : ReadGrant τ snapshot.session p) (c : Criteria)
    {n : Note} (h : n ∈ (read grant c).rows) :
    n ∈ snapshot.notes ∧ CanRead snapshot.session p n :=
  ⟨(visible_sound (page_subset h)).1, (read grant c).authorized n h⟩

theorem read_exact (grant : ReadGrant τ snapshot.session p) (c : Criteria) :
    (read grant c).rows = page (visible p snapshot.notes) c := rfl

inductive Operation where
  | list | lookup | search | count | export
  deriving BEq, Repr

structure NoteView where
  id : Nat
  title : String
  body : String
  deriving DecidableEq, BEq, Repr

def Note.project (n : Note) : NoteView := ⟨n.id, n.title, n.body⟩

structure Response where
  notes : List NoteView := []
  count : Nat := 0
  notFound : Bool := false
  tooMany : Bool := false
  deriving BEq, Repr

/-- Fixed response semantics. Counts/limits/export all consume the same scoped relation. -/
def respond (rows : List Note) (op : Operation) (c : Criteria) : Response :=
  let selected := matching rows c
  match op with
  | .count => { count := selected.length }
  | .lookup =>
    { notes := (selected.take 1).map Note.project, count := min selected.length 1,
      notFound := selected.isEmpty }
  | .export =>
    if selected.length > 100 then { tooMany := true }
    else { notes := selected.map Note.project, count := selected.length }
  | .list | .search =>
    { notes := (page rows c).map Note.project, count := selected.length }

def handleModel (snapshot : Snapshot) (p : Principal) (op : Operation) (c : Criteria) :
    Except String Response := do
  let _ ← authorize Unit snapshot.session p
  pure (respond (visible p snapshot.notes) op c)

theorem respond_provenance {rows : List Note} {op : Operation} {c : Criteria}
    {v : NoteView} (h : v ∈ (respond rows op c).notes) :
    ∃ n ∈ rows, n.project = v := by
  cases op <;> simp only [respond] at h
  · obtain ⟨n, hn, hv⟩ := List.mem_map.mp h
    exact ⟨n, page_subset hn, hv⟩
  · obtain ⟨n, hn, hv⟩ := List.mem_map.mp h
    exact ⟨n, (List.mem_filter.mp (List.mem_of_mem_take hn)).1, hv⟩
  · obtain ⟨n, hn, hv⟩ := List.mem_map.mp h
    exact ⟨n, page_subset hn, hv⟩
  · simp at h
  · split at h
    · simp at h
    · obtain ⟨n, hn, hv⟩ := List.mem_map.mp h
      exact ⟨n, (List.mem_filter.mp hn).1, hv⟩

theorem response_sound (grant : ReadGrant τ snapshot.session p) (op : Operation) (c : Criteria)
    {v : NoteView} (h : v ∈ (respond (visible p snapshot.notes) op c).notes) :
    ∃ n ∈ snapshot.notes, CanRead snapshot.session p n ∧ n.project = v := by
  obtain ⟨n, hn, hv⟩ := respond_provenance h
  obtain ⟨hs, ho⟩ := visible_sound hn
  exact ⟨n, hs, ⟨grant.valid, ho⟩, hv⟩

theorem handleModel_success (h : SessionValid snapshot.session p) (op : Operation) (c : Criteria) :
    handleModel snapshot p op c = .ok (respond (visible p snapshot.notes) op c) := by
  simp [handleModel, authorize, h]
  rfl

/-- Equal authorized views and authority facts imply equal modeled responses for all
five operations. No timing, FFI failures, logs, or cryptographic claims are made. -/
theorem response_noninterference (a b : Snapshot) (p : Principal)
    (facts : a.session = b.session) (view : visible p a.notes = visible p b.notes)
    (op : Operation) (c : Criteria) : handleModel a p op c = handleModel b p op c := by
  cases a
  cases b
  cases facts
  simp_all only [handleModel]

end PrivateNotes
