import Lean

/-
Checkout workshop. Run: lake env lean docs/blog/workshop/Checkout.lean

This is an executable teaching model, not a payment integration. Prices use
minor units and a deliberately simple local formula. A real service still
owns prices, quote expiry, availability, and payment authorization.
-/
namespace CheckoutWorkshop

-- A draft may be empty. The checked quantity used below is always 1..99.
abbrev Quantity := { n : Nat // 0 < n ∧ n ≤ 99 }

-- This small ASCII parser uses the current LeanJS string operations.
-- Lean's String.toNat? currently reaches an unsupported native extern.
private def digitValue (char : Char) : Option Nat :=
  match String.singleton char with
  | "0" => some 0 | "1" => some 1 | "2" => some 2 | "3" => some 3
  | "4" => some 4 | "5" => some 5 | "6" => some 6 | "7" => some 7
  | "8" => some 8 | "9" => some 9 | _ => none

def parseQuantity (raw : String) : Except String Quantity := do
  if raw.isEmpty then throw "Enter a quantity."
  let n ← raw.toList.foldlM (fun total char => do
    let some digit := digitValue char | throw "Use whole numbers."
    pure (total * 10 + digit)) 0
  if h : 0 < n ∧ n ≤ 99 then return ⟨n, h⟩
  else throw "Choose between 1 and 99 items."

-- A capability, with an implementation chosen from the argument's type.
class Priced (α : Type) where
  price : α → Nat

open Priced

structure Items where
  quantity : Quantity
  unitPrice : Nat
  deriving DecidableEq

structure Pickup where
  store : String
  deriving DecidableEq

inductive Speed where
  | standard | express
  deriving DecidableEq

structure Delivery where
  address : String
  speed : Speed
  deriving DecidableEq

-- Address/store validation is outside this sketch's quantity and quote rules.
instance : Priced Items where
  price items := items.quantity.val * items.unitPrice

instance : Priced Pickup where
  price _ := 0

instance : Priced Delivery where
  price delivery := match delivery.speed with
    | .standard => 500
    | .express => 1200

-- "Both": additive prices compose. This rule is for independent charges.
instance [Priced α] [Priced β] : Priced (α × β) where
  price pair := price pair.1 + price pair.2

-- "Either": only the selected alternative contributes a charge.
instance [Priced α] [Priced β] : Priced (α ⊕ β) where
  price choice := match choice with
    | .inl left => price left
    | .inr right => price right

-- The type means: items AND (pickup OR delivery).
abbrev Input := Items × (Pickup ⊕ Delivery)

-- A new priced part uses the existing product instance and checkout lifecycle.
structure GiftWrap where
  message : String
  deriving DecidableEq

instance : Priced GiftWrap where
  price _ := 300

abbrev GiftInput := Input × GiftWrap

-- Generations also distinguish two requests for the SAME selection.
structure Request (α : Type) where
  input : α
  generation : Nat
  deriving DecidableEq

structure Quote {α : Type} [Priced α] (request : Request α) where
  amount : Nat
  correct : amount = price request.input

-- This supplies the local demo's service response. It makes no network call.
def calculateQuote [Priced α] (request : Request α) : Quote request :=
  ⟨price request.input, rfl⟩

-- One generic lifecycle, preserving the request/quote relationship.
inductive Checkout (α : Type) [Priced α] where
  | editing (input : α)
  | loading (request : Request α)
  | ready (request : Request α) (quote : Quote request)
  | failed (request : Request α) (message : String)

def Checkout.input [Priced α] : Checkout α → α
  | .editing input => input
  | .loading request => request.input
  | .ready request _ => request.input
  | .failed request _ => request.input

structure Controller (α : Type) [Priced α] where
  generation : Nat := 0
  state : Checkout α

-- An edit invalidates the accepted quote. A new request starts separately.
def edit [Priced α] (controller : Controller α) (input : α) : Controller α :=
  { controller with state := .editing input }

def begin [Priced α] (controller : Controller α) : Controller α × Request α :=
  let request : Request α := {
    input := controller.state.input
    generation := controller.generation + 1
  }
  ({ generation := request.generation, state := .loading request }, request)

-- The payload's type records the request that produced it, even on failure.
structure Reply (α : Type) [Priced α] where
  request : Request α
  result : Except String (Quote request)

def succeed [Priced α] (request : Request α) : Reply α :=
  ⟨request, .ok (calculateQuote request)⟩

def failRequest [Priced α] (request : Request α) (message : String) : Reply α :=
  ⟨request, .error message⟩

-- This is a RUNTIME equality check. The successful branch supplies evidence
-- that permits moving the response into the current request's ready state.
def receive [Priced α] [DecidableEq α]
    (controller : Controller α) (reply : Reply α) : Controller α :=
  match controller.state with
  | .loading current =>
    if same : reply.request = current then
      let result : Except String (Quote current) := same ▸ reply.result
      { controller with state := match result with
        | .ok quote => .ready current quote
        | .error message => .failed current message }
    else controller
  | _ => controller

-- Presentational flags are derived, so they cannot disagree with the state.
def status [Priced α] (controller : Controller α) : String :=
  match controller.state with
  | .editing _ => "editing"
  | .loading _ => "loading"
  | .ready _ _ => "ready"
  | .failed _ _ => "failed"

def payableAmount [Priced α] (controller : Controller α) : Option Nat :=
  match controller.state with
  | .ready _ quote => some quote.amount
  | .editing _ | .loading _ | .failed _ _ => none

-- Two mugs, $12 each. Standard delivery costs $5; pickup costs nothing.
def items : Items := ⟨⟨2, by decide⟩, 1200⟩
def delivery : Input := (items, .inr ⟨"14 Oak Street", .standard⟩)
def pickup : Input := (items, .inl ⟨"Main Street"⟩)
def gift : GiftInput := (pickup, ⟨"Happy birthday!"⟩)
def initial : Controller Input := ⟨0, .editing delivery⟩
def deliveryRun := begin initial
def pickupRun := begin (edit deliveryRun.1 pickup)
def pickupReady := receive pickupRun.1 (succeed pickupRun.2)
def giftRun := begin ({ state := .editing gift } : Controller GiftInput)

-- There is no hand-written Priced Input or Priced GiftInput instance.
#guard price delivery == 2900
#guard price pickup == 2400
#guard price gift == 2700

-- An old response cannot be used as a quote for the current request.
#check_failure (Checkout.ready pickupRun.2 (calculateQuote deliveryRun.2))
#check_failure (show Quantity from ⟨0, by decide⟩)

-- These checks also run against the generated JavaScript during the workshop.
def regressionChecks : List Bool := [
  !(parseQuantity "").isOk,
  !(parseQuantity "0").isOk,
  !(parseQuantity "100").isOk,
  !(parseQuantity "2x").isOk,
  !(parseQuantity "-1").isOk,
  (parseQuantity "2").isOk,
  price delivery == 2900,
  price pickup == 2400,
  price gift == 2700,
  status (receive pickupRun.1 (succeed deliveryRun.2)) == "loading",
  status (receive pickupRun.1 (failRequest deliveryRun.2 "Old error")) == "loading",
  payableAmount (receive pickupRun.1 (succeed deliveryRun.2)) == none,
  payableAmount pickupReady == some 2400,
  payableAmount (edit pickupReady delivery) == none,
  payableAmount (receive giftRun.1 (succeed giftRun.2)) == some 2700,
  status (receive pickupRun.1 (failRequest pickupRun.2 "Try again")) == "failed",
  -- Retrying the same selection still invalidates the earlier request.
  status (receive (begin pickupRun.1).1 (succeed pickupRun.2)) == "loading",
  -- A second response cannot replace an already settled result.
  status (receive pickupReady (failRequest pickupRun.2 "Late error")) == "ready"
]

#guard regressionChecks.all id

end CheckoutWorkshop
