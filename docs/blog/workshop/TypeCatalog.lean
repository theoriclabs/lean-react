import Lean
import Std

/- Executable examples for type_catalog.md.
   Check with: lake env lean docs/blog/workshop/TypeCatalog.lean
   These examples target Lean itself, not the LeanJS compilation subset. -/
universe u
namespace TypeCatalog

-- Enumerations, records, alternatives, and record extension.
inductive Method where
  | pickup | delivery
  deriving DecidableEq

structure Pickup where
  store : String

structure Delivery where
  address : String

structure ScheduledDelivery extends Delivery where
  slot : Nat

inductive Fulfillment where
  | pickup (details : Pickup)
  | delivery (details : Delivery)

abbrev BasicOrder := Nat × Fulfillment

-- A computed type family.
def Details : Method → Type
  | .pickup => Pickup
  | .delivery => Delivery

-- A dependent record and the corresponding dependent-pair shape.
structure Selection where
  method : Method
  details : Details method

abbrev PackedSelection := (method : Method) × Details method

def selectedPickup : Selection := ⟨.pickup, ⟨"Main Street"⟩⟩
def packedPickup : PackedSelection := ⟨.pickup, ⟨"Main Street"⟩⟩

def describeSelection (method : Method) (details : Details method) : String :=
  match method with
  | .pickup => details.store
  | .delivery => details.address

#guard describeSelection .pickup ⟨"Main Street"⟩ == "Main Street"
#check_failure (show Selection from ⟨.pickup, ({ address := "14 Oak Street" } : Delivery)⟩)

-- Functions, higher-order functions, Pi types, and polymorphism.
def renderNumber : Nat → String := toString
def transformTwice (f : Nat → Nat) (n : Nat) : Nat := f (f n)
def copies (n : Nat) : Vector String n := Vector.replicate n "item"
def polymorphicIdentity (α : Type u) (value : α) : α := value
def usePolymorphic (f : (α : Type) → α → α) : Nat × String :=
  (f Nat 2, f String "hello")

-- Generic types and universe-polymorphic types.
structure Box (α : Type u) where
  value : α

example : Box Nat := ⟨2⟩
example : Box Type := ⟨Nat⟩

-- Phantom parameters distinguish identities without adding a runtime field.
structure EntityId (entity : Type) where
  value : Nat

inductive UserTag where | tag
inductive OrderTag where | tag
def userId : EntityId UserTag := ⟨7⟩
#check_failure (show EntityId OrderTag from userId)

-- Transparent aliases do not introduce that distinction.
abbrev UserNumber := Nat
example : UserNumber := (7 : Nat)

-- Subtypes and records with proofs.
abbrev Quantity := { n : Nat // 0 < n ∧ n ≤ 99 }
def quantity : Quantity := ⟨2, by decide⟩
#check_failure (show Quantity from ⟨0, by decide⟩)

structure Booking where
  ticketCount : Nat
  seats : List Nat
  sameCount : seats.length = ticketCount

def booking : Booking := ⟨2, [10, 11], by decide⟩

-- An indexed inductive family. Constructors determine the stage index.
inductive Stage where
  | draft | ready | paid

inductive Order : Stage → Type where
  | draft (note : String) : Order .draft
  | ready (amount : Nat) : Order .ready
  | paid (receipt : String) : Order .paid

def amountDue : Order .ready → Nat
  | .ready amount => amount

#check_failure amountDue (Order.draft "Still editing")

-- Recursive, nested, and mutually recursive inductive types.
inductive Rule where
  | minimum (amount : Nat)
  | both (left right : Rule)

inductive Tree (α : Type) where
  | node (value : α) (children : List (Tree α))

mutual
  inductive Menu where
    | item (label : String) (children : Menus)
  inductive Menus where
    | empty
    | more (first : Menu) (rest : Menus)
end

-- Sigma retains a witness as data. Exists states that a witness exists.
def someSizedList : (n : Nat) × Vector String n := ⟨2, copies 2⟩
theorem aPositiveNumberExists : ∃ n : Nat, 0 < n := ⟨2, by decide⟩
theorem quantityIsPositive : 0 < quantity.val := quantity.property.1
example : 2 + 3 = 5 := rfl
example : HEq (2 : Nat) (2 : Nat) := HEq.rfl

-- A runtime decision can supply evidence used to create a checked value.
def checkQuantity (n : Nat) : Option Quantity :=
  if h : 0 < n ∧ n ≤ 99 then some ⟨n, h⟩ else none

#guard (checkQuantity 2).isSome
#guard (checkQuantity 0).isNone

-- Type classes and recursively composed instances.
class Priced (α : Type) where
  price : α → Nat

instance : Priced Quantity where
  price n := n.val * 1200

instance [Priced α] [Priced β] : Priced (α × β) where
  price pair := Priced.price pair.1 + Priced.price pair.2

#guard Priced.price (quantity, quantity) == 4800

-- A parameter that is itself a type constructor: F : Type → Type.
def addOneInside {F : Type → Type} [Functor F] (values : F Nat) : F Nat :=
  (fun n => n + 1) <$> values

#guard addOneInside (some 2) == some 3
#guard addOneInside [2, 3] == [3, 4]

-- Quotients identify values using a chosen equivalence relation.
def sameLastDigit : Setoid Nat where
  r a b := a % 10 = b % 10
  iseqv := {
    refl := fun _ => rfl
    symm := fun h => h.symm
    trans := fun h₁ h₂ => h₁.trans h₂
  }

abbrev LastDigit := Quotient sameLastDigit
example : (Quotient.mk sameLastDigit 12 : LastDigit) =
    Quotient.mk sameLastDigit 22 := Quotient.sound (by rfl)

-- Representative standard-library types used in the catalog.
#check Rat
#check Float32
#check BitVec
#check Fin
#check Vector
#check Std.HashMap
#check Std.TreeMap
#check Std.DHashMap
#check Thunk
#check Task
#check IO.Ref
#check ReaderT
#check StateT
#check ExceptT
#check Decidable
#check Nonempty
#check Inhabited
#check Subsingleton
#check LawfulFunctor
#check ULift
#check PLift
#check Lean.TSyntax

end TypeCatalog
