import Lean

/- Focused examples for state_space_composition.md.
   Run: lake env lean docs/blog/workshop/StateSpaceComposition.lean
   These check Lean's type system, not browser rendering or LeanJS support. -/
namespace StateSpaceComposition

-- A class with an associated draft type and a round-trip law.
-- Each parser must return its declared (possibly refined) type.
class Editor (Value : Type) where
  Draft : Type
  parse : Draft → Except String Value
  format : Value → Draft
  roundtrip : ∀ value, parse (format value) = .ok value

instance : Editor Nat where
  Draft := Nat
  parse := .ok
  format := id
  roundtrip _ := rfl

def parsePair [Editor A] [Editor B]
    (draft : Editor.Draft A × Editor.Draft B) : Except String (A × B) := do
  let a ← Editor.parse draft.1
  let b ← Editor.parse draft.2
  pure (a, b)

theorem pairRoundtrip [Editor A] [Editor B] (value : A × B) :
    parsePair (Editor.format value.1, Editor.format value.2) = .ok value := by
  simp only [parsePair, Editor.roundtrip]
  rfl

instance [Editor A] [Editor B] : Editor (A × B) where
  Draft := Editor.Draft A × Editor.Draft B
  parse := parsePair
  format value := (Editor.format value.1, Editor.format value.2)
  roundtrip := pairRoundtrip

def parseRefined [Editor A] (P : A → Prop) [DecidablePred P]
    (draft : Editor.Draft A) : Except String { value : A // P value } := do
  let value ← Editor.parse draft
  if h : P value then pure ⟨value, h⟩ else throw "These values do not fit together."

theorem refinedRoundtrip [Editor A] (P : A → Prop) [DecidablePred P]
    (value : { a : A // P a }) :
    parseRefined P (Editor.format value.val) = .ok value := by
  simp only [parseRefined, Editor.roundtrip]
  change (if h : P value.val then Except.ok (⟨value.val, h⟩ : { a : A // P a })
    else Except.error "These values do not fit together.") = Except.ok value
  simp only [dif_pos value.property]

instance [Editor A] {P : A → Prop} [DecidablePred P] : Editor { a : A // P a } where
  Draft := Editor.Draft A
  parse := parseRefined P
  format value := Editor.format value.val
  roundtrip := refinedRoundtrip P

-- A small four-day model so that the counts can be checked exhaustively.
-- Each endpoint is valid on its own; the window adds a relationship.
abbrev Day := { n : Nat // 1 ≤ n ∧ n ≤ 4 }
abbrev Window := { pair : Day × Day // pair.1.val ≤ pair.2.val }

def readWindow (draft : Nat × Nat) : Except String Window := Editor.parse draft

#guard (readWindow (1, 4)).isOk
#guard (readWindow (3, 3)).isOk
#guard !(readWindow (4, 1)).isOk
#guard !(readWindow (0, 2)).isOk
#guard !(readWindow (2, 5)).isOk

-- The draft type is inferred through two refinement levels and a product.
example : Editor.Draft Window = (Nat × Nat) := rfl

def pairs : List (Nat × Nat) :=
  [1, 2, 3, 4].flatMap fun start => [1, 2, 3, 4].map fun finish => (start, finish)

#guard pairs.length == 16
#guard (pairs.filter fun pair => (readWindow pair).isOk).length == 10

-- Combining predicates means checking the SAME value against both rules.
abbrev Positive := { n : Fin 4 // 0 < n.val }
abbrev BelowThree := { n : Fin 4 // n.val < 3 }
abbrev Both := { n : Fin 4 // 0 < n.val ∧ n.val < 3 }

#guard ((List.finRange 4).filter fun n => decide (0 < n.val)).length == 3
#guard ((List.finRange 4).filter fun n => decide (n.val < 3)).length == 3
#guard ((List.finRange 4).filter fun n => decide (0 < n.val ∧ n.val < 3)).length == 2

-- Several artifacts share one context. The context index is not an extra
-- independent runtime choice for each artifact.
structure Quote (snapshot : Fin 4) where
  amount : Nat

structure Authorization (snapshot : Fin 4) where
  reference : String

abbrev ReadyCheckout := (snapshot : Fin 4) × Quote snapshot × Authorization snapshot

def quoteForZero : Quote 0 := ⟨2400⟩
def authorizationForZero : Authorization 0 := ⟨"local-demo"⟩
def ready : ReadyCheckout := ⟨0, quoteForZero, authorizationForZero⟩
#check_failure (show ReadyCheckout from ⟨1, quoteForZero, authorizationForZero⟩)

-- Dependencies can refer to earlier dependent fields, not just a common tag.
structure QuoteAuthorization {snapshot : Fin 4} (quote : Quote snapshot) where
  reference : String

structure ReadyChain where
  snapshot : Fin 4
  quote : Quote snapshot
  authorization : QuoteAuthorization quote

def approvedQuote : QuoteAuthorization quoteForZero := ⟨"local-demo"⟩
def chained : ReadyChain := ⟨0, quoteForZero, approvedQuote⟩
#check_failure (show ReadyChain from ⟨0, ⟨2900⟩, approvedQuote⟩)

-- Count only ownership labels here, not amounts or reference strings.
def triples : List (Nat × Nat × Nat) :=
  (List.range 4).flatMap fun a => (List.range 4).flatMap fun b =>
    (List.range 4).map fun c => (a, b, c)

#guard triples.length == 64
#guard (triples.filter fun (a, b, c) => a == b && b == c).length == 4

-- A computed description of valid choices, itself assembled from smaller
-- descriptions. The two interpreters compute a type and its finite count.
inductive Shape where
  | choice (options : Nat)
  | both (left right : Shape)
  | either (left right : Shape)
  | depending (options : Nat) (rest : Fin options → Shape)

def Shape.Value : Shape → Type
  | .choice n => Fin n
  | .both left right => left.Value × right.Value
  | .either left right => left.Value ⊕ right.Value
  | .depending n rest => (choice : Fin n) × (rest choice).Value

def Shape.count : Shape → Nat
  | .choice n => n
  | .both left right => left.count * right.count
  | .either left right => left.count + right.count
  | .depending n rest => ((List.finRange n).map fun choice => (rest choice).count).sum

-- For this hypothetical shop, four countries allow 3, 2, 2, and 1 services.
def shipping : Shape := .depending 4 fun country =>
  .choice (match country.val with | 0 => 3 | 1 => 2 | 2 => 2 | _ => 1)

#guard shipping.count == 8
example : 4 * 4 = 16 := by decide

-- A selected mode determines the whole remaining form shape.
-- Pickup: 4 stores. Delivery: 3 addresses, each with 2 possible slots.
def fulfillment : Shape := .either (.choice 4) (.both (.choice 3) (.choice 2))
#guard fulfillment.count == 10
example : 2 * 4 * 3 * 2 = 48 := by decide

-- Slot choice only applies on the delivery side.
def pickupSelection : fulfillment.Value := .inl (2 : Fin 4)
def deliverySelection : fulfillment.Value := .inr ((1 : Fin 3), (0 : Fin 2))
#check_failure (show fulfillment.Value from Sum.inl ((2 : Fin 4), (0 : Fin 2)))

-- Cardinality and uniqueness are separate constraints.
abbrev TwoSeats := { seats : Vector (Fin 4) 2 // seats.toList.Nodup }
def validSeats : TwoSeats := ⟨⟨#[0, 1], by decide⟩, by decide⟩
#guard (pairs.filter fun (first, second) => first != second).length == 12

-- A typed protocol: local steps compose only when their endpoints match.
inductive Phase where
  | editing | quoted | authorized

inductive Step : Phase → Phase → Type where
  | quote : Step .editing .quoted
  | authorize : Step .quoted .authorized

inductive Path : Phase → Phase → Type where
  | done : Path phase phase
  | next : Step first middle → Path middle last → Path first last

def checkoutPath : Path .editing .authorized := .next .quote (.next .authorize .done)
#check_failure (show Path .editing .authorized from Path.next Step.authorize Path.done)

-- Five independent four-way choices determine fifteen additional fields.
-- This bound assumes those fifteen fields are deterministic functions of
-- the choices; arbitrary related fields need not reduce this far.
example : 4 ^ 20 = 1099511627776 := by decide
example : 4 ^ 5 = 1024 := by decide

end StateSpaceComposition
