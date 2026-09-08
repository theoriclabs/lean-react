import PrivateNotes
open PrivateNotes

instance [BEq ε] [BEq α] : BEq (Except ε α) where
  beq a b := match a, b with
    | .ok a, .ok b => a == b
    | .error a, .error b => a == b
    | _, _ => false

def alice : Principal := ⟨"alice", "studio", 1⟩
def facts : SessionFacts := ⟨"alice", "studio", 1, 1, true, 200, 100⟩
def fixture : Snapshot := ⟨facts, [
  ⟨101, "alice", "studio", "Launch budget", "ALICE-DEMO-101"⟩,
  ⟨102, "alice", "studio", "Garden notes", "ALICE-DEMO-102"⟩,
  ⟨201, "bob", "studio", "Launch budget", "BOB-DEMO-201"⟩,
  ⟨301, "alice", "archive", "Launch budget", "ARCHIVE-DEMO-301"⟩]⟩

#guard (visible alice fixture.notes).map (·.id) == [101, 102]
#guard (handleModel fixture alice .list {}).map (·.count) == .ok 2
#guard (handleModel fixture alice .search { search := "budget" }).map (·.count) == .ok 1
#guard (handleModel fixture alice .export {}).map (fun r => r.notes.map (·.body)) ==
  .ok ["ALICE-DEMO-101", "ALICE-DEMO-102"]
#guard handleModel fixture alice .lookup { id := some 201 } ==
  handleModel fixture alice .lookup { id := some 999 }
#guard handleModel fixture alice .lookup { id := some 301 } ==
  handleModel fixture alice .lookup { id := some 999 }
#guard (handleModel fixture alice .list { offset := 1, limit := 1 }).map
  (fun r => (r.count, r.notes.map (·.id))) == .ok (2, [102])
#guard (handleModel fixture alice .search { search := "' OR 1=1 --" }).map (·.count) == .ok 0
#guard (handleModel fixture alice .search { search := "%" }).map (·.count) == .ok 0
#guard handleModel { fixture with session := { facts with enabled := false } } alice .list {} ==
  .error "auth.required"
#guard handleModel { fixture with session := { facts with currentGeneration := 2 } } alice .list {} ==
  .error "auth.required"
#guard handleModel { fixture with session := { facts with now := 200 } } alice .list {} ==
  .error "auth.required"

def grant : ReadGrant Unit facts alice :=
  (authorize Unit facts alice).toOption.get (by decide)

#guard match certify grant fixture.notes with | .error _ => true | _ => false
#guard match certify grant (visible alice fixture.notes) with | .ok _ => true | _ => false

-- Useful success and provenance, not just an always-denying security theorem.
example : SessionValid facts alice := by decide
#guard (read (snapshot := fixture) grant {}).rows.map (·.id) == [101, 102]

#print axioms ownedPredicate_sound
#print axioms ownedPredicate_exact
#print axioms visible_sound
#print axioms visible_exact
#print axioms read_sound
#print axioms read_exact
#print axioms response_sound
#print axioms handleModel_success
#print axioms response_noninterference

def main : IO Unit := IO.println "PASS: ownership, tenant, search, count, export, pagination, revocation, checked reconstruction and model proofs"
