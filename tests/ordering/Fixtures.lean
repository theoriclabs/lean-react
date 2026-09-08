import Ordering

namespace Ordering.Fixtures

def rule (amount : Nat) : PricingRule .usd :=
  { base := ⟨amount⟩, adjustments := #[([.milk .oat], 75), ([.size .large], 125)] }

def offer (amount : Nat) (label : String) : Offer .usd :=
  { id := ⟨7⟩, label, revision := 11, ruleRevision := 19, rule := rule amount, quoteLifetime := 10 }

def require (condition : Bool) (message : String) : Except String Unit :=
  if condition then .ok () else .error message

def expectError [BEq e] (value : Except e a) (expected : e) (message : String) : Except String Unit :=
  match value with
  | .error actual => require (actual == expected) message
  | .ok _ => .error (message ++ ": unexpectedly accepted")

def success (value : Except e a) (message : String) : Except String a := value.mapError (fun _ => message)

/-- Parameterized so parity executes the same decision functions at runtime, not only constants. -/
def scenario (amount : Nat) (label : String) : Except String (Array String) := do
  let initial := Memory.empty (offer amount label) 2
  let request : Quote := ⟨⟨7⟩, { milk := .oat, size := .large }, 2⟩
  let (quotedMemory, quoted) ← success (initial.quote 100 request) "quote"
  require (quoted.unitPrice.minor == amount + 200) "unit price"
  require (quoted.total.minor == (amount + 200) * 2) "exact total"
  require (quoted.label == label && quoted.offerRevision == 11 && quoted.ruleRevision == 19) "binding"
  require (quoted.issuedAt == 100 && quoted.expiresAt == 110) "lifetime"
  require (quotedMemory.stock.reserved == 0 && quoted.id.value == 1) "quote does not reserve"
  expectError (initial.placeOrder 101 ⟨quoted.id⟩) .quoteNotFound "unknown quote"
  expectError (initial.quote 100 { request with offerId := ⟨8⟩ }) .offerNotFound "unknown offer"
  expectError (initial.quote 100 { request with quantity := 0 }) .zeroQuantity "zero quantity"
  expectError (initial.quote 100 { request with configuration := { temperature := .iced, size := .small } })
    (.preview (.configuration .smallIced)) "inadmissible quote"
  let negativeRule : PricingRule .usd := { base := ⟨0⟩, adjustments := #[([], -1)] }
  expectError ((initial.changeRule negativeRule).quote 100 request)
    (.preview (.pricing (.negativeTotal (-1)))) "unpriceable quote"
  expectError ((initial.changeOffer label 0).quote 100 request) .zeroLifetime "zero lifetime"
  expectError (quotedMemory.placeOrder 99 ⟨quoted.id⟩) .notYetValid "future quote"
  expectError (quotedMemory.placeOrder 110 ⟨quoted.id⟩) .expired "expiry boundary"
  expectError (quotedMemory.placeOrder 111 ⟨quoted.id⟩) .expired "expired"
  expectError ((quotedMemory.changeRule (rule (amount + 1))).placeOrder 101 ⟨quoted.id⟩)
    .ruleChanged "changed rule"
  expectError ((quotedMemory.changeOffer (label ++ "!") 10).placeOrder 101 ⟨quoted.id⟩)
    .offerChanged "changed offer"
  let changed := (quotedMemory.changeRule (rule (amount + 1))).changeOffer (label ++ "!") 20
  let (freshMemory, fresh) ← success (changed.quote 101 request) "requote"
  require (fresh.ruleRevision == 20 && fresh.offerRevision == 12 &&
    fresh.unitPrice.minor == amount + 201 && fresh.label == label ++ "!" && fresh.expiresAt == 121) "fresh bindings"
  let (_, freshOrder) ← success (freshMemory.placeOrder 120 ⟨fresh.id⟩) "accept fresh quote"
  require (freshOrder.placement.quote.total.minor == (amount + 201) * 2) "fresh total"
  let (placedMemory, placed) ← success (quotedMemory.placeOrder 109 ⟨quoted.id⟩) "place"
  require (placed.placement.quote.total.minor == quoted.total.minor) "no reprice"
  require (placed.placement.id.value == 1 && placedMemory.stock.reserved == 2) "reservation"
  expectError (placedMemory.placeOrder 109 ⟨quoted.id⟩) .alreadyUsed "duplicate placement"
  let (secondMemory, secondQuote) ← success (placedMemory.quote 109 request) "second quote"
  require (secondQuote.id.value == 2) "deterministic quote ids"
  expectError (secondMemory.placeOrder 109 ⟨secondQuote.id⟩) (.stock .insufficientCapacity) "last stock"
  expectError (placedMemory.cancelOrder 110 ⟨⟨999⟩, "reason"⟩) .orderNotFound "missing order"
  expectError (placedMemory.cancelOrder 110 ⟨placed.placement.id, ""⟩) .emptyReason "empty reason"
  expectError (placedMemory.cancelOrder 108 ⟨placed.placement.id, label⟩) .beforePlacement "cancellation time"
  let (cancelledMemory, cancelled) ← success
    (secondMemory.cancelOrder 110 ⟨placed.placement.id, label⟩) "cancel"
  require (cancelledMemory.stock.reserved == 0 && cancelled.placement.id == placed.placement.id) "release"
  expectError (cancelledMemory.cancelOrder 110 ⟨placed.placement.id, label⟩) .alreadyCancelled "double cancel"
  expectError (cancelledMemory.placeOrder 110 ⟨quoted.id⟩) .alreadyUsed "cancel does not revive quote"
  let (replacedMemory, replacement) ← success
    (cancelledMemory.placeOrder 110 ⟨secondQuote.id⟩) "released capacity reusable"
  require (replacement.placement.id.value == 2 && replacedMemory.stock.reserved == 2) "deterministic order ids"
  let receipt : Receipt .usd := ⟨label, quoted.total, 110⟩
  expectError (placed.pay { receipt with reference := "" }) .emptyReference "receipt reference"
  expectError (placed.pay { receipt with amount := ⟨quoted.total.minor + 1⟩ }) .amountMismatch "receipt amount"
  expectError (placed.pay { receipt with receivedAt := 108 }) .beforePlacement "receipt time"
  let (paidMemory, paid) ← success (placedMemory.confirmPayment placed.placement.id receipt) "payment"
  require (paid.placement.quote.total.minor == quoted.total.minor) "paid amount"
  expectError (paidMemory.cancelOrder 111 ⟨placed.placement.id, label⟩) .alreadyPaid "paid cancellation"
  expectError (paidMemory.confirmPayment placed.placement.id receipt) .invalidState "double payment"
  expectError (cancelledMemory.confirmPayment placed.placement.id receipt) .invalidState "cancelled payment"
  expectError (initial.confirmPayment ⟨999⟩ receipt) .orderNotFound "missing payment order"
  -- Old snapshots remain unchanged on both success and rejection.
  require (initial.stock.reserved == 0 && placedMemory.stock.reserved == 2 &&
    cancelledMemory.stock.reserved == 0) "immutable snapshots"
  pure #[quoted.label, toString quoted.unitPrice.minor, toString quoted.total.minor,
    toString replacedMemory.stock.reserved, "transitions:ok"]

def pricingCases (amount : Nat) : Except String (Array String) := do
  expectError (preview (rule amount) { temperature := .iced, size := .small })
    (.configuration .smallIced) "small iced"
  expectError (preview (rule amount) { decaf := true, shots := .triple })
    (.configuration .decafTriple) "decaf triple"
  let bad : PricingRule .usd := { base := ⟨amount⟩, adjustments := #[([], -(Int.ofNat amount) - 1)] }
  expectError (preview bad {}) (.pricing (.negativeTotal (-1))) "negative price"
  let discounted : PricingRule .usd := { base := ⟨amount + 10⟩, adjustments := #[([], -10)] }
  let discount ← success (preview discounted {}) "discount"
  require (discount.minor == amount) "exact discount"
  let overridden := { bad with overrides := #[([.milk .oat], ⟨42⟩), ([], ⟨99⟩)] }
  let overridePrice ← success (preview overridden { milk := .oat }) "override"
  require (overridePrice.minor == 42) "first override wins, replaces adjustments"
  let configs := Configuration.all
  require (configs.size == 180) "finite space"
  let valid := configs.filter Configuration.admissible
  require (valid.size == 125) "admissible space"
  let totals := valid.foldl (fun sum c =>
    match preview (rule amount) c with | .ok price => sum + price.minor | .error _ => sum) 0
  pure #[toString discount.minor, toString overridePrice.minor, toString totals, "pricing:ok"]

def stockCases (capacity : Nat) : Except String (Array String) := do
  expectError (Stock.fromRaw capacity (capacity + 1)) .invalidCapacity "reconstruct stock"
  let stock ← success (Stock.fromRaw (capacity + 1) 0) "valid stock"
  expectError (stock.reserve 0) .zeroQuantity "reserve zero"
  expectError (stock.release 0) .zeroQuantity "release zero"
  expectError (stock.release 1) .insufficientReserved "release unreserved"
  let full ← success (stock.reserve (capacity + 1)) "reserve exact capacity"
  expectError (full.reserve 1) .insufficientCapacity "overflow capacity"
  let empty ← success (full.release (capacity + 1)) "release all"
  require (empty.reserved == 0 && empty.capacity == capacity + 1) "release preservation"
  pure #[toString full.reserved, toString empty.reserved, "stock:ok"]

end Ordering.Fixtures
