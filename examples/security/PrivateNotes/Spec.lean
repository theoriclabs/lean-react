import Std

/-! The reviewed specification. Candidate query changes must preserve these definitions.
Authentication/storage fidelity are host obligations, not axioms asserted here. -/
namespace PrivateNotes

structure Principal where
  actor : String
  tenant : String
  generation : Nat
  deriving DecidableEq, BEq, Repr

structure SessionFacts where
  actor : String
  tenant : String
  generation : Nat
  currentGeneration : Nat
  enabled : Bool
  expiresAt : Nat
  now : Nat
  deriving DecidableEq, BEq, Repr

structure Note where
  id : Nat
  owner : String
  tenant : String
  title : String
  body : String
  deriving DecidableEq, BEq, Repr

def SessionValid (s : SessionFacts) (p : Principal) : Prop :=
  s.actor = p.actor ∧ s.tenant = p.tenant ∧ s.generation = p.generation ∧
  s.currentGeneration = p.generation ∧ s.enabled = true ∧ s.now < s.expiresAt

instance : Decidable (SessionValid s p) := inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _))

def Owned (p : Principal) (n : Note) : Prop := n.owner = p.actor ∧ n.tenant = p.tenant
instance : Decidable (Owned p n) := inferInstanceAs (Decidable (_ ∧ _))

def CanRead (s : SessionFacts) (p : Principal) (n : Note) : Prop :=
  SessionValid s p ∧ Owned p n

structure Snapshot where
  session : SessionFacts
  notes : List Note
  deriving Repr

end PrivateNotes
