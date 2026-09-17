import Lean

/- Additional executable examples for the state-space guides.
   Run: lake env lean docs/blog/workshop/guides/GuideExamples.lean
   These examples check Lean itself. They are not a browser integration. -/
namespace StateSpaceGuides

namespace Conditional
structure Pickup where
  store : String
structure Delivery where
  address : String
  slot : Nat
inductive Fulfillment where
  | pickup (details : Pickup)
  | delivery (details : Delivery)
def describe : Fulfillment → String
  | .pickup details => "Collect from " ++ details.store
  | .delivery details => "Deliver to " ++ details.address
#guard describe (.pickup ⟨"Main Street"⟩) == "Collect from Main Street"
#check_failure (Fulfillment.pickup ({ address := "Oak Street", slot := 1 } : Delivery))
end Conditional

namespace Choices
inductive Country where
  | north | south
  deriving DecidableEq
inductive Service where
  | standard | express
  deriving DecidableEq
def serves : Country → Service → Prop
  | .north, _ => True
  | .south, .standard => True
  | .south, .express => False
instance (country : Country) (service : Service) : Decidable (serves country service) :=
  match country, service with
  | .north, _ => isTrue True.intro
  | .south, .standard => isTrue True.intro
  | .south, .express => isFalse id
abbrev AvailableService (country : Country) := { service : Service // serves country service }
abbrev Shipping := (country : Country) × AvailableService country
def check (country : Country) (service : Service) : Except String (AvailableService country) :=
  if h : serves country service then .ok ⟨service, h⟩
  else .error "That service is unavailable here."
#guard (check .north .express).isOk
#guard !(check .south .express).isOk
#check_failure (show AvailableService .south from ⟨.express, by decide⟩)
end Choices

namespace Relations
abbrev Window := { pair : Nat × Nat // pair.1 ≤ pair.2 }
def check (start finish : Nat) : Except String Window :=
  if h : start ≤ finish then .ok ⟨(start, finish), h⟩
  else .error "The end must not be before the start."
def moveStart (window : Window) (start : Nat) : Except String Window :=
  check start window.val.2
#guard (check 1 4).isOk
#guard !(check 4 1).isOk
#guard !(moveStart ⟨(1, 4), by decide⟩ 5).isOk
end Relations

namespace Intersections
def positive (n : Nat) : Prop := 0 < n
def small (n : Nat) : Prop := n < 4
abbrev Positive := { n : Nat // positive n }
abbrev Small := { n : Nat // small n }
abbrev Both := { n : Nat // positive n ∧ small n }
-- Combining checks for the same value requires agreement about that value.
def combine (a : Positive) (b : Small) (same : a.val = b.val) : Both :=
  ⟨a.val, a.property, same.symm ▸ b.property⟩
def checkedTwo : Both := combine ⟨2, by exact Nat.zero_lt_succ 1⟩
  ⟨2, by show 2 < 4; decide⟩ rfl
#check_failure (combine ⟨2, by exact Nat.zero_lt_succ 1⟩
  ⟨3, by show 3 < 4; decide⟩ (by decide))
end Intersections

namespace Collections
structure Show where
  id : Nat
  revision : Nat
  available : List Nat
  deriving DecidableEq
structure Seat (performance : Show) where
  number : Nat
  available : number ∈ performance.available
structure Selection (performance : Show) (count : Nat) where
  seats : Vector (Seat performance) count
  distinct : (seats.toList.map fun seat => seat.number).Nodup
def checkSeat (performance : Show) (number : Nat) : Option (Seat performance) :=
  if h : number ∈ performance.available then some ⟨number, h⟩ else none
def afternoon : Show := ⟨1, 0, [10, 11, 12]⟩
def evening : Show := ⟨2, 0, [10, 11, 12]⟩
def a : Seat afternoon := ⟨10, by decide⟩
def b : Seat afternoon := ⟨11, by decide⟩
def two : Selection afternoon 2 := ⟨⟨#[a, b], by decide⟩, by decide⟩
#guard (checkSeat afternoon 10).isSome
#guard (checkSeat afternoon 99).isNone
#check_failure (show Seat evening from a)
#check_failure (show Selection afternoon 2 from ⟨⟨#[a], by decide⟩, by decide⟩)
#check_failure (show Selection afternoon 2 from ⟨⟨#[a, a], by decide⟩, by decide⟩)
end Collections

namespace Chains
structure Clinic where
  id : Nat
  revision : Nat
structure Clinician (clinic : Clinic) where
  id : Nat
structure Slot {clinic : Clinic} (clinician : Clinician clinic) where
  startsAt : Nat
structure Reservation {clinic : Clinic} {clinician : Clinician clinic} (slot : Slot clinician) where
  reference : String
structure Appointment where
  clinic : Clinic
  clinician : Clinician clinic
  slot : Slot clinician
  reservation : Reservation slot
def clinic : Clinic := ⟨1, 0⟩
def alice : Clinician clinic := ⟨10⟩
def bob : Clinician clinic := ⟨11⟩
def aliceSlot : Slot alice := ⟨900⟩
def aliceReservation : Reservation aliceSlot := ⟨"local-demo"⟩
def appointment : Appointment := ⟨clinic, alice, aliceSlot, aliceReservation⟩
#check_failure (show Appointment from ⟨clinic, bob, aliceSlot, aliceReservation⟩)
end Chains

namespace Compatibility
inductive Provider where
  | card | bank
  deriving DecidableEq
inductive Currency where
  | usd | eur
  deriving DecidableEq
def supported : Provider → Currency → Bool
  | .card, _ => true
  | .bank, .usd => true
  | .bank, .eur => false
class Supports (provider : Provider) (currency : Currency) : Prop where
  allowed : supported provider currency = true
instance : Supports .card .usd := ⟨rfl⟩
instance : Supports .card .eur := ⟨rfl⟩
instance : Supports .bank .usd := ⟨rfl⟩
-- This is a route-description function, not a payment operation.
def prepare (provider : Provider) (currency : Currency) [Supports provider currency] : String :=
  match provider, currency with
  | .card, .usd => "card/USD"
  | .card, .eur => "card/EUR"
  | .bank, _ => "bank/USD"
def prepareChoice (provider : Provider) (currency : Currency) : Except String String :=
  if h : supported provider currency = true then
    letI : Supports provider currency := ⟨h⟩
    .ok (prepare provider currency)
  else .error "Choose a supported provider and currency."
#guard prepare .card .eur == "card/EUR"
#check_failure prepare .bank .eur
#guard (prepareChoice .bank .usd).isOk
#guard !(prepareChoice .bank .eur).isOk
end Compatibility

namespace Derived
structure Cart where
  quantity : Nat
  unitPrice : Nat
  shipping : Nat
def Cart.total (cart : Cart) : Nat := cart.quantity * cart.unitPrice + cart.shipping
structure PricedCart where
  cart : Cart
  total : Nat
  agrees : total = cart.total
def price (cart : Cart) : PricedCart := ⟨cart, cart.total, rfl⟩
def resize (priced : PricedCart) (quantity : Nat) : PricedCart :=
  price { priced.cart with quantity }
def original : PricedCart := price ⟨1, 1200, 500⟩
#guard original.total == 1700
#guard (resize original 2).total == 2900
#check_failure (show PricedCart from ⟨⟨2, 1200, 500⟩, 1700, by decide⟩)
end Derived

namespace Equivalent
abbrev RawSeats := { pair : Fin 4 × Fin 4 // pair.1 ≠ pair.2 }
abbrev OrderedSeats := { pair : Fin 4 × Fin 4 // pair.1 < pair.2 }
def canonical (first second : Fin 4) : Option OrderedSeats :=
  if h : first < second then some ⟨(first, second), h⟩
  else if h : second < first then some ⟨(second, first), h⟩
  else none
def key (seats : RawSeats) : Nat × Nat :=
  (min seats.val.1.val seats.val.2.val, max seats.val.1.val seats.val.2.val)
def sameSelection : Setoid RawSeats where
  r a b := key a = key b
  iseqv := {
    refl := fun _ => rfl
    symm := fun h => h.symm
    trans := fun h₁ h₂ => h₁.trans h₂
  }
abbrev SeatSet := Quotient sameSelection
def ab : RawSeats := ⟨(0, 1), by decide⟩
def ba : RawSeats := ⟨(1, 0), by decide⟩
example : (Quotient.mk sameSelection ab : SeatSet) =
    Quotient.mk sameSelection ba := Quotient.sound (by rfl)
#guard (canonical 0 1).map Subtype.val == (canonical 1 0).map Subtype.val
#guard ((canonical 1 0).bind fun seats => canonical seats.val.1 seats.val.2).map Subtype.val ==
  (canonical 1 0).map Subtype.val
#guard (canonical 1 1).isNone
def allPairs := (List.finRange 4).flatMap fun a => (List.finRange 4).map fun b => (a, b)
#guard (allPairs.filter fun (a, b) => a != b).length == 12
#guard (allPairs.filter fun (a, b) => a < b).length == 6
end Equivalent

end StateSpaceGuides
