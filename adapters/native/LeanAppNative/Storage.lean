import LeanDb.Core
import LeanOntology.Identity

/-! Checked representations at the boundary between a domain and SQLite.
No blanket domain-to-row derivation or publication is implied by a mapping. -/
namespace LeanAppNative.Storage
open LeanDb Ontology

/-- SQLite INTEGER is signed 64-bit. Unlike LeanDb's legacy Nat codec,
this value cannot silently narrow an arbitrary-precision natural number. -/
structure SqlNat where
  private mk ::
  value : Nat
  bounded : value ≤ 9223372036854775807
  deriving Repr, DecidableEq

def SqlNat.ofNat (n : Nat) : Except String SqlNat :=
  if h : n ≤ 9223372036854775807 then .ok ⟨n, h⟩
  else .error "storage.nat_out_of_range"

instance : ColCodec SqlNat := ColCodec.via (β := Int64)
  (fun n => Int64.ofNat n.value)
  (fun n => if n < 0 then .error "storage.negative_nat" else SqlNat.ofNat n.toNatClampNeg)

instance : SqlOrd SqlNat where

/-- Arbitrary-precision revisions and amounts use canonical decimal TEXT.
There is deliberately no SqlOrd instance: lexical order is not numeric order. -/
structure ExactNat where
  value : Nat
  deriving Repr, DecidableEq

def ExactNat.parse (s : String) : Except String ExactNat := do
  let some n := s.toNat? | throw "storage.invalid_nat"
  if toString n != s then throw "storage.noncanonical_nat"
  return ⟨n⟩

instance : ColCodec ExactNat := ColCodec.via (β := String)
  (fun n => toString n.value) ExactNat.parse

/-- Physical columns are not authority. Reconstruct the nominal ID at reads;
the store must separately resolve its indexed internal row and access policy. -/
structure PublicIdColumns where
  scope : String
  key : String
  deriving Repr, DecidableEq

def PublicIdColumns.encode (id : EntityId α) : PublicIdColumns :=
  ⟨id.scope.value, id.key⟩

def PublicIdColumns.decode (columns : PublicIdColumns) : Validation (EntityId α) :=
  EntityId.parse columns.scope columns.key

/-- A mapping owns a stable physical representation, not a public operation.
Both directions are checked; richer domains may require reconstruction across
several rows before returning a value. Schema/migration lineage remains in DB. -/
structure Mapping (Domain Row : Type) where
  table : String
  identity : String
  encode : Domain → Except String Row
  decode : Row → Except String Domain

end LeanAppNative.Storage
