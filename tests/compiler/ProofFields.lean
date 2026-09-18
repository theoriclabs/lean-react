import LeanJS.Portable

/-! LR-10/LR-11: structures-with-proof-fields, subtypes, `Fin`, a decidable
`Normal` over arrays, nested proof-carrying records, and ∀-index `Chain`. -/

namespace ProofFields

abbrev Len := Nat
abbrev Count := { n : Nat // 0 < n }

def Count.make (n : Nat) : Option Count :=
  if h : 0 < n then some ⟨n, h⟩ else none

instance : Inhabited Count where
  default := ⟨1, Nat.zero_lt_succ 0⟩

def Count.add (a b : Count) : Count :=
  match Count.make (a.val + b.val) with
  | some c => c
  | none => a

structure Text where
  s : String
  nonempty : 0 < s.length
  noBreak : s.toList.all (· ≠ '\n') = true

def Text.make (s : String) : Option Text :=
  if h : 0 < s.length then
    if h2 : s.toList.all (· ≠ '\n') = true then some ⟨s, h, h2⟩ else none
  else none

instance : Inhabited Text where
  default := ⟨"x", by decide, by decide⟩

def Text.append (a b : Text) : Text :=
  match Text.make (a.s ++ b.s) with
  | some t => t
  | none => a

abbrev Indent := Fin 9

def Indent.ofNat? (n : Nat) : Option Indent :=
  if h : n < 9 then some ⟨n, h⟩ else none

inductive Op where
  | insert (t : Text)
  | retain (n : Count)
  | delete (n : Count)

instance : Inhabited Op where
  default := .retain default

def Op.base : Op → Len
  | .insert _ => 0
  | .retain n | .delete n => n.val

def Op.target : Op → Len
  | .insert t => t.s.length
  | .retain n => n.val
  | .delete _ => 0

/-- Adjacent same-kind ops merge; `insert` then `delete` at a cursor is swapped. -/
def Op.mergeable (a b : Op) : Option Op :=
  match a, b with
  | .insert t1, .insert t2 => some (.insert (Text.append t1 t2))
  | .retain n1, .retain n2 => some (.retain (Count.add n1 n2))
  | .delete n1, .delete n2 => some (.delete (Count.add n1 n2))
  | _, _ => none

def Op.insertThenDelete : Op → Op → Bool
  | .insert _, .delete _ => true
  | _, _ => false

/-- Tail-recursive: no adjacent mergeable pair, no insert-then-delete, nonempty
    arrays end with `retain`. -/
def Normal.go (ops : Array Op) (i : Nat) : Bool :=
  if i ≥ ops.size then true
  else
    let op := ops.getD i default
    let last := i + 1 == ops.size
    let okEnd := !last || match op with | .retain _ => true | _ => false
    let okPair :=
      if i + 1 < ops.size then
        let nxt := ops.getD (i + 1) default
        (Op.mergeable op nxt).isNone && !(Op.insertThenDelete op nxt)
      else true
    if okEnd && okPair then Normal.go ops (i + 1) else false
termination_by ops.size - i

def Normal.check (ops : Array Op) : Bool := Normal.go ops 0

def Normal (ops : Array Op) : Prop := Normal.check ops = true

theorem Normal.check_iff (ops : Array Op) : Normal.check ops = true ↔ Normal ops := Iff.rfl

instance : DecidablePred Normal := fun ops =>
  if h : Normal.check ops then .isTrue h else .isFalse (fun hn => h hn)

/-- Merge adjacent pairs and put `delete` before `insert` at a position. -/
def Delta.normalize.go (ops : Array Op) (i : Nat) (acc : Array Op) : Array Op :=
  if i ≥ ops.size then acc
  else
    let op := ops.getD i default
    let acc' :=
      if acc.size == 0 then acc.push op
      else
        let last := acc.getD (acc.size - 1) default
        match Op.mergeable last op with
        | some merged => acc.pop.push merged
        | none =>
          if Op.insertThenDelete last op then
            let rest := acc.pop
            if rest.size == 0 then #[op, last]
            else
              let prev := rest.getD (rest.size - 1) default
              match Op.mergeable prev op with
              | some merged => rest.pop.push merged |>.push last
              | none => rest.push op |>.push last
          else acc.push op
    Delta.normalize.go ops (i + 1) acc'
termination_by ops.size - i

def Delta.normalize (ops : Array Op) : Array Op :=
  Delta.normalize.go ops 0 #[]

structure Delta where
  ops : Array Op
  normal : Normal ops

def Delta.ofOps (ops : Array Op) : Option Delta :=
  let ops := Delta.normalize ops
  if h : Normal ops then some ⟨ops, h⟩ else none

def Delta.base (d : Delta) : Len := d.ops.foldl (fun acc op => acc + op.base) 0
def Delta.target (d : Delta) : Len := d.ops.foldl (fun acc op => acc + op.target) 0

structure Run where
  text : Text
  fmt : Nat

structure Paragraph where
  runs : Array Run
  block : Indent

structure Doc where
  paragraphs : Array Paragraph

def Doc.len (d : Doc) : Len :=
  d.paragraphs.foldl (fun acc p =>
    acc + p.runs.foldl (fun a r => a + r.text.s.length) 0) 0

def Doc.empty : Doc := ⟨#[]⟩

def Doc.apply (doc : Doc) (d : Delta) (_h : d.base = doc.len) : Doc :=
  let inserted := d.ops.foldl (fun acc op =>
    match op with
    | .insert t => acc.push ⟨#[⟨t, 0⟩], ⟨0, by decide⟩⟩
    | .retain _ | .delete _ => acc) doc.paragraphs
  ⟨inserted⟩

def Delta.compose (a b : Delta) (_h : a.target = b.base) : Option Delta :=
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

/-- Consecutive `+ 1` from `0`. The proof fields are ∀-quantified over indices. -/
def Chain.checkDense (nodes : Array Nat) : Bool :=
  (List.range nodes.size).all fun i =>
    decide (i + 1 ≥ nodes.size) || decide (nodes.getD i 0 + 1 = nodes.getD (i + 1) 0)

def Chain.checkFirst (nodes : Array Nat) : Bool :=
  decide (nodes.size = 0) || decide (nodes.getD 0 0 = 0)

def Chain.checkLinked (nodes : Array Nat) : Bool :=
  (List.range nodes.size).all fun i =>
    (List.range nodes.size).all fun j =>
      decide (j ≤ i) || decide (nodes.getD i 0 < nodes.getD j 0)

private theorem of_all_range {p : Nat → Bool} {n i : Nat}
    (h : (List.range n).all p = true) (hi : i < n) : p i = true :=
  (List.all_eq_true.mp h) i (List.mem_range.mpr hi)

theorem Chain.dense_of_check {nodes : Array Nat} (h : Chain.checkDense nodes = true)
    (i : Nat) (hi : i + 1 < nodes.size) :
    nodes.getD i 0 + 1 = nodes.getD (i + 1) 0 := by
  have hall := of_all_range (p := fun i =>
    decide (i + 1 ≥ nodes.size) || decide (nodes.getD i 0 + 1 = nodes.getD (i + 1) 0))
    h (Nat.lt_of_succ_lt hi)
  have hge : decide (i + 1 ≥ nodes.size) = false := decide_eq_false (Nat.not_le_of_gt hi)
  simp [Array.getD, hge, Bool.false_or, decide_eq_true_eq] at hall ⊢
  exact hall

theorem Chain.first_of_check {nodes : Array Nat} (h : Chain.checkFirst nodes = true) :
    nodes.size = 0 ∨ nodes.getD 0 0 = 0 := by
  unfold Chain.checkFirst at h
  simp only [Bool.or_eq_true, decide_eq_true_eq] at h
  exact h

theorem Chain.getD_eq {nodes : Array Nat} (hd : Chain.checkDense nodes = true)
    (hf : Chain.checkFirst nodes = true) (i : Nat) (hi : i < nodes.size) :
    nodes.getD i 0 = i := by
  induction i with
  | zero =>
    have := Chain.first_of_check hf
    cases this with
    | inl hsz => exact (Nat.not_lt_zero _ (hsz ▸ hi)).elim
    | inr h0 => exact h0
  | succ i ih =>
    have hprev : i < nodes.size := Nat.lt_of_succ_lt hi
    have hstep := Chain.dense_of_check hd i (by omega)
    have := ih hprev
    omega

theorem Chain.linked_of_check {nodes : Array Nat} (hd : Chain.checkDense nodes = true)
    (hf : Chain.checkFirst nodes = true) (i j : Nat) (hij : i < j) (hj : j < nodes.size) :
    nodes.getD i 0 < nodes.getD j 0 := by
  have hi : i < nodes.size := Nat.lt_trans hij hj
  have hi' := Chain.getD_eq hd hf i hi
  have hj' := Chain.getD_eq hd hf j hj
  omega

structure Chain where
  nodes : Array Nat
  dense : ∀ i, i + 1 < nodes.size → nodes.getD i 0 + 1 = nodes.getD (i + 1) 0
  first : nodes.size = 0 ∨ nodes.getD 0 0 = 0
  linked : ∀ i j, i < j → j < nodes.size → nodes.getD i 0 < nodes.getD j 0

def Chain.make (nodes : Array Nat) : Option Chain :=
  if hd : Chain.checkDense nodes = true then
    if hf : Chain.checkFirst nodes = true then
      some ⟨nodes, Chain.dense_of_check hd, Chain.first_of_check hf, Chain.linked_of_check hd hf⟩
    else none
  else none

/-- Combined fixture for the parity runner. -/
def score (doc : String) (insert : String) (n : Nat) : Nat :=
  match Text.make insert, Count.make (n + 1), Indent.ofNat? (n % 9) with
  | some t, some c, some indent =>
    let d0 : Doc :=
      match Text.make doc with
      | some body => ⟨#[⟨#[⟨body, 0⟩], indent⟩]⟩
      | none => Doc.empty
    let empty := Delta.ofOps #[]
    let applied := empty.bind (applyChecked Doc.empty)
    let delta := Delta.ofOps #[.insert t, .retain c]
    t.s.length + c.val + indent.val + Sync.serverLen (.aligned d0.len)
      + identityCast 1
      + (match applied, delta with
         | some _, some d => if decide (Normal d.ops) then 1 else 0
         | _, _ => 0)
  | _, _, _ => 0

end ProofFields
