import LeanJS.Portable

/-! LR-10: structures-with-proof-fields, subtypes, `Fin`, proof arguments, states. -/

namespace ProofFields

abbrev Len := Nat
abbrev Count := { n : Nat // 0 < n }

def Count.make (n : Nat) : Option Count :=
  if h : 0 < n then some ⟨n, h⟩ else none

structure Text where
  s : String
  nonempty : 0 < s.length
  noBreak : s.toList.all (· ≠ '\n') = true

def Text.make (s : String) : Option Text :=
  if h : 0 < s.length then
    if h2 : s.toList.all (· ≠ '\n') = true then some ⟨s, h, h2⟩ else none
  else none

abbrev Indent := Fin 9

def Indent.ofNat? (n : Nat) : Option Indent :=
  if h : n < 9 then some ⟨n, h⟩ else none

inductive Op where
  | insert (t : Text)
  | retain (n : Count)
  | delete (n : Count)

def Op.base : Op → Len
  | .insert _ => 0
  | .retain n | .delete n => n.val

def Op.target : Op → Len
  | .insert t => t.s.length
  | .retain n => n.val
  | .delete _ => 0

def Normal (_ops : Array Op) : Prop := True
instance : DecidablePred Normal := fun _ => .isTrue trivial

structure Delta where
  ops : Array Op
  normal : Normal ops

def Delta.ofOps (ops : Array Op) : Delta := ⟨ops, trivial⟩
def Delta.base (d : Delta) : Len := d.ops.foldl (fun acc op => acc + op.base) 0
def Delta.target (d : Delta) : Len := d.ops.foldl (fun acc op => acc + op.target) 0

structure Doc where
  body : String

def Doc.len (d : Doc) : Len := d.body.length
def Doc.empty : Doc := ⟨""⟩

def Doc.apply (doc : Doc) (d : Delta) (_h : d.base = doc.len) : Doc :=
  ⟨doc.body ++ d.ops.foldl (fun acc op =>
    match op with
    | .insert t => acc ++ t.s
    | .retain _ | .delete _ => acc) ""⟩

def Delta.compose (a b : Delta) (_h : a.target = b.base) : Delta :=
  Delta.ofOps (a.ops ++ b.ops)

structure Range (n : Len) where
  index : Len
  length : Len
  inBounds : index + length ≤ n

structure Span where
  index : Len
  length : Count

def Span.check (n : Len) (s : Span) : Option (Range n) :=
  if h : s.index + s.length.val ≤ n then some ⟨s.index, s.length.val, h⟩ else none

inductive Sync where
  | aligned (len : Len)
  | inflight (base server : Len)
  | resync
  deriving Repr, DecidableEq

def Sync.serverLen : Sync → Len
  | .aligned n => n
  | .inflight _ s => s
  | .resync => 0

/-- Type-equality cast on a parameterized structure; LeanJS should treat `▸` as identity. -/
def Range.cast {n m : Len} (h : n = m) (r : Range n) : Range m := h ▸ r

def identityCast (n : Nat) : Nat :=
  let r : Range n := ⟨0, 0, Nat.zero_le n⟩
  (Range.cast (Nat.add_zero n).symm r).index + n

def applyChecked (doc : Doc) (d : Delta) : Option Doc :=
  if h : d.base = doc.len then some (doc.apply d h) else none

/-- Combined fixture for the parity runner. -/
def score (doc : String) (insert : String) (n : Nat) : Nat :=
  match Text.make insert, Count.make (n + 1), Indent.ofNat? (n % 9) with
  | some t, some c, some indent =>
    let d0 : Doc := ⟨doc⟩
    let empty := Delta.ofOps #[]
    let applied := applyChecked ⟨""⟩ empty
    let delta := Delta.ofOps #[.insert t]
    t.s.length + c.val + indent.val + Sync.serverLen (.aligned d0.len)
      + identityCast 1
      + (if applied.isSome && decide (Normal delta.ops) then 1 else 0)
  | _, _, _ => 0

end ProofFields
