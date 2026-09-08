import Ordering.Domain.Pricing

namespace Ordering

structure OfferId where
  value : Nat
  deriving Repr, BEq, DecidableEq
structure QuoteId where
  value : Nat
  deriving Repr, BEq, DecidableEq
structure OrderId where
  value : Nat
  deriving Repr, BEq, DecidableEq

structure Offer (currency : Currency) where
  id : OfferId
  label : String
  revision : Nat
  ruleRevision : Nat
  rule : PricingRule currency
  /-- Clock ticks, in the same unit as the explicit `now` argument. -/
  quoteLifetime : Nat

structure Quote where
  offerId : OfferId
  configuration : Configuration
  quantity : Nat

inductive QuoteError where
  | offerNotFound | zeroQuantity | zeroLifetime
  | preview (error : PreviewError)
  deriving Repr, BEq, DecidableEq

/-- Issued by the authoritative interpreter and retained in its quote book. -/
structure Quoted (currency : Currency) where
  private mk ::
  id : QuoteId
  offerId : OfferId
  offerRevision : Nat
  ruleRevision : Nat
  label : String
  configuration : AdmissibleConfiguration
  quantity : Nat
  positive : 0 < quantity
  unitPrice : Money currency
  total : Money currency
  exactTotal : total = unitPrice.scale quantity
  issuedAt : Nat
  expiresAt : Nat

structure PlaceOrder where
  quoteId : QuoteId

inductive PlaceOrderError where
  | quoteNotFound | alreadyUsed | offerChanged | ruleChanged | expired | notYetValid
  | stock (error : StockError)
  deriving Repr, BEq, DecidableEq

structure CancelOrder where
  orderId : OrderId
  reason : String

inductive CancelOrderError where
  | orderNotFound | alreadyCancelled | alreadyPaid | emptyReason | beforePlacement
  | stock (error : StockError)
  deriving Repr, BEq, DecidableEq

inductive Stage where
  | placed | paid | cancelled
  deriving Repr, BEq, DecidableEq

structure Placement (currency : Currency) where
  id : OrderId
  quote : Quoted currency
  placedAt : Nat

structure Receipt (currency : Currency) where
  reference : String
  amount : Money currency
  receivedAt : Nat

/-- Each alternative carries its required evidence/history. Stage indices prevent
    passing a cancelled order to payment confirmation (or a paid order to cancellation). -/
inductive Order (currency : Currency) : Stage → Type where
  | placed (placement : Placement currency) : Order currency .placed
  | paid (placement : Placement currency) (receipt : Receipt currency) : Order currency .paid
  | cancelled (placement : Placement currency) (reason : String) (cancelledAt : Nat) :
      Order currency .cancelled

def Order.placement : Order c s → Placement c
  | .placed p => p
  | .paid p _ => p
  | .cancelled p _ _ => p

inductive PaymentError where
  | emptyReference | amountMismatch | beforePlacement
  deriving Repr, BEq, DecidableEq

def Order.pay (order : Order c .placed) (receipt : Receipt c) :
    Except PaymentError (Order c .paid) :=
  if receipt.reference.isEmpty then .error .emptyReference
  else if receipt.amount.minor != order.placement.quote.total.minor then .error .amountMismatch
  else if receipt.receivedAt < order.placement.placedAt then .error .beforePlacement
  else .ok (.paid order.placement receipt)

def Order.cancel (order : Order c .placed) (reason : String) (now : Nat) :
    Except CancelOrderError (Order c .cancelled) :=
  if reason.isEmpty then .error .emptyReason
  else if now < order.placement.placedAt then .error .beforePlacement
  else .ok (.cancelled order.placement reason now)

inductive StoredOrder (currency : Currency) where
  | placed (order : Order currency .placed)
  | paid (order : Order currency .paid)
  | cancelled (order : Order currency .cancelled)

def StoredOrder.placement : StoredOrder c → Placement c
  | .placed o => o.placement
  | .paid o => o.placement
  | .cancelled o => o.placement

/-- Single-offer deterministic interpreter. Quotes do not reserve stock. Accepted
    orders do; cancellation releases once. A paid order retains its reservation.
    Private construction prevents forging a quote book or reservation history. -/
structure Memory (currency : Currency) where
  private mk ::
  offer : Offer currency
  stock : Stock
  quotes : List (Quoted currency)
  orders : List (StoredOrder currency)
  nextQuote : Nat
  nextOrder : Nat

def Memory.empty (offer : Offer c) (capacity : Nat) : Memory c :=
  ⟨offer, Stock.empty capacity, [], [], 1, 1⟩

/-- Rule updates always advance the rule revision. Outstanding quotes become stale. -/
def Memory.changeRule (memory : Memory c) (rule : PricingRule c) : Memory c :=
  { memory with offer := { memory.offer with rule, ruleRevision := memory.offer.ruleRevision + 1 } }

def Memory.changeOffer (memory : Memory c) (label : String) (quoteLifetime : Nat) : Memory c :=
  { memory with offer := { memory.offer with label, quoteLifetime, revision := memory.offer.revision + 1 } }

def Memory.quote (memory : Memory c) (now : Nat) (input : Quote) :
    Except QuoteError (Memory c × Quoted c) := do
  if input.offerId != memory.offer.id then throw .offerNotFound
  if h : 0 < input.quantity then
    if memory.offer.quoteLifetime == 0 then throw .zeroLifetime
    let config ← input.configuration.check.mapError (QuoteError.preview ∘ PreviewError.configuration)
    let unitPrice ← (memory.offer.rule.evaluate config).mapError (QuoteError.preview ∘ PreviewError.pricing)
    let quoted : Quoted c := ⟨⟨memory.nextQuote⟩, memory.offer.id, memory.offer.revision,
      memory.offer.ruleRevision, memory.offer.label, config, input.quantity, h,
      unitPrice, unitPrice.scale input.quantity, rfl, now, now + memory.offer.quoteLifetime⟩
    pure ({ memory with quotes := quoted :: memory.quotes, nextQuote := memory.nextQuote + 1 }, quoted)
  else throw .zeroQuantity

/-- Consumes a retained quote, never evaluates the current rule or accepts a client price.
    The exact expiry tick is already expired. Used quotes remain used after cancellation. -/
def Memory.placeOrder (memory : Memory c) (now : Nat) (input : PlaceOrder) :
    Except PlaceOrderError (Memory c × Order c .placed) := do
  let some quoted := memory.quotes.find? (fun q => q.id == input.quoteId)
    | throw .quoteNotFound
  if memory.orders.any (fun o => o.placement.quote.id == input.quoteId) then throw .alreadyUsed
  if quoted.offerId != memory.offer.id || quoted.offerRevision != memory.offer.revision then throw .offerChanged
  if quoted.ruleRevision != memory.offer.ruleRevision then throw .ruleChanged
  if now < quoted.issuedAt then throw .notYetValid
  if now ≥ quoted.expiresAt then throw .expired
  let stock ← (memory.stock.reserve quoted.quantity).mapError PlaceOrderError.stock
  let order := Order.placed (⟨⟨memory.nextOrder⟩, quoted, now⟩ : Placement c)
  pure ({ memory with stock, orders := .placed order :: memory.orders, nextOrder := memory.nextOrder + 1 }, order)

def Memory.cancelOrder (memory : Memory c) (now : Nat) (input : CancelOrder) :
    Except CancelOrderError (Memory c × Order c .cancelled) := do
  let some stored := memory.orders.find? (fun o => o.placement.id == input.orderId)
    | throw .orderNotFound
  match stored with
  | .paid _ => throw .alreadyPaid
  | .cancelled _ => throw .alreadyCancelled
  | .placed placed =>
    let cancelled ← placed.cancel input.reason now
    let stock ← (memory.stock.release placed.placement.quote.quantity).mapError CancelOrderError.stock
    pure ({ memory with stock, orders := memory.orders.map (fun o =>
      if o.placement.id == input.orderId then .cancelled cancelled else o) }, cancelled)

inductive ConfirmPaymentError where
  | orderNotFound | invalidState
  | payment (error : PaymentError)
  deriving Repr, BEq, DecidableEq

def Memory.confirmPayment (memory : Memory c) (id : OrderId) (receipt : Receipt c) :
    Except ConfirmPaymentError (Memory c × Order c .paid) := do
  let some stored := memory.orders.find? (fun o => o.placement.id == id) | throw .orderNotFound
  match stored with
  | .placed placed =>
    let paid ← (placed.pay receipt).mapError ConfirmPaymentError.payment
    pure ({ memory with orders := memory.orders.map (fun o =>
      if o.placement.id == id then .paid paid else o) }, paid)
  | _ => throw .invalidState

end Ordering
