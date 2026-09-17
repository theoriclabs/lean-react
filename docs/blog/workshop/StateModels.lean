import Lean

/-
Workshop sketches, separate from the introduction post.
Run: lake env lean docs/blog/workshop/StateModels.lean

These count the choices explicitly listed, not text inputs, network events,
or every possible history. They illustrate different modeling techniques.
-/
namespace StateWorkshop

-- Independent choices multiply. Nesting records would not change the count.
structure Latte where
  size : Fin 3
  milk : Fin 4

example : 3 * 4 = 12 := by decide
example : 4 ^ 20 = 1099511627776 := by decide

-- A configured order for a shop with physical and downloadable products.
-- Count only fulfillment choices: 4 stores, 3 shipping speeds, 2 file formats.
-- An incomplete form would have its own draft state.
inductive FulfillmentMode where
  | pickup | delivery | download

structure FlatFulfillment where
  mode : FulfillmentMode
  store : Fin 4
  shippingSpeed : Fin 3
  fileFormat : Fin 2

inductive Fulfillment where
  | pickup (store : Fin 4)
  | delivery (shippingSpeed : Fin 3)
  | download (fileFormat : Fin 2)

example : 3 * 4 * 3 * 2 = 72 := by decide
example : 4 + 3 + 2 = 9 := by decide

-- Strictly sequential workflow. No parallel work, retries, or failures in
-- this small model. Earlier steps are done; later steps are locked.
inductive StepStatus where
  | locked | ready | running | done
  deriving BEq, Repr

abbrev FlatWorkflow (steps : Nat) := Fin steps → StepStatus

inductive Workflow (steps : Nat) where
  | ready (step : Fin steps)
  | running (step : Fin steps)
  | complete

def Workflow.status (workflow : Workflow n) (step : Fin n) : StepStatus :=
  match workflow with
  | .complete => .done
  | .ready current =>
      if step.val < current.val then .done
      else if step.val == current.val then .ready
      else .locked
  | .running current =>
      if step.val < current.val then .done
      else if step.val == current.val then .running
      else .locked

example : 20 + 20 + 1 = 41 := by decide
#guard (Workflow.running (2 : Fin 20)).status 0 == .done
#guard (Workflow.running (2 : Fin 20)).status 2 == .running
#guard (Workflow.running (2 : Fin 20)).status 3 == .locked

-- Cinema booking: the count is chosen at runtime. The draft can be incomplete.
-- This small model checks count and distinctness. Seat availability and show
-- identity would need their own checks at the reservation boundary.
structure BookingDraft where
  ticketCount : Nat
  seats : List Nat

structure Booking where
  ticketCount : Nat
  seats : List Nat
  countMatches : seats.length = ticketCount
  noDuplicates : seats.Nodup

def validateBooking (draft : BookingDraft) : Except String Booking :=
  if hcount : draft.seats.length = draft.ticketCount then
    if hunique : draft.seats.Nodup then
      .ok ⟨draft.ticketCount, draft.seats, hcount, hunique⟩
    else .error "Choose different seats."
  else .error "Choose one seat for each ticket."

def threeSeats : Booking := ⟨3, [7, 8, 9], by decide, by decide⟩

-- Both incomplete selection and duplicate seats are rejected by the type.
#check_failure (show Booking from ⟨3, [7, 8], by decide, by decide⟩)
#check_failure (show Booking from ⟨3, [7, 7, 8], by decide, by decide⟩)

#guard (validateBooking ⟨3, [7, 8, 9]⟩).isOk
#guard !(validateBooking ⟨3, [7, 8]⟩).isOk
#guard !(validateBooking ⟨3, [7, 7, 8]⟩).isOk

-- A quote belongs to the cart it was calculated for. This is a toy price
-- formula, not a payment integration or a claim about server authorization.
structure Cart where
  quantity : Nat
  unitPrice : Nat
  shipping : Nat
  deriving DecidableEq

def Cart.total (cart : Cart) : Nat :=
  cart.quantity * cart.unitPrice + cart.shipping

structure Quote (cart : Cart) where
  total : Nat
  correct : total = cart.total

def makeQuote (cart : Cart) : Quote cart := ⟨cart.total, rfl⟩

def amountToCharge (cart : Cart) (quote : Quote cart) : Nat := quote.total

inductive Checkout where
  | editing (cart : Cart)
  | ready (cart : Cart) (quote : Quote cart)

def Checkout.cart : Checkout → Cart
  | .editing cart => cart
  | .ready cart _ => cart

-- Any edit returns the checkout to the state that needs a quote.
def changeQuantity (checkout : Checkout) (quantity : Nat) : Checkout :=
  .editing { checkout.cart with quantity }

def oneItem : Cart := ⟨1, 1200, 500⟩
def twoItems : Cart := ⟨2, 1200, 500⟩
def originalQuote : Quote oneItem := makeQuote oneItem

#guard amountToCharge oneItem originalQuote == 1700
#guard amountToCharge twoItems (makeQuote twoItems) == 2900
#check_failure amountToCharge twoItems originalQuote

-- Keeping the previous quote while changing the cart does not typecheck.
#check_failure (Checkout.ready twoItems originalQuote)

-- Valid states alone do not enforce a workflow's history. A public constructor
-- can still create .complete directly. Transition rules require APIs or proofs
-- of their own. Likewise, trusted input still needs validation at boundaries.
end StateWorkshop
