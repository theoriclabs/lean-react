import Ordering

open Ordering

example : (Money.add (⟨9007199254740993⟩ : Money .usd) ⟨7⟩).minor = 9007199254741000 := rfl
example (s : Stock) : s.reserved ≤ s.capacity := s.fits
example (c : AdmissibleConfiguration) : c.value.admissible = true := c.valid
example (q : Quoted c) : q.total = q.unitPrice.scale q.quantity := q.exactTotal
example (q : Quoted c) : 0 < q.quantity := q.positive
example (order : Order .usd .placed) (receipt : Receipt .usd) :
    Except PaymentError (Order .usd .paid) := order.pay receipt
example (order : Order .usd .placed) : Except CancelOrderError (Order .usd .cancelled) :=
  order.cancel "customer changed mind" (order.placement.placedAt + 1)

#guard Configuration.all.size == 180
#guard (Configuration.all.filter Configuration.admissible).size == 125
#guard (Configuration.check { temperature := .iced, size := .small }).isOk == false
#guard (Stock.fromRaw 2 3).isOk == false
#guard (Stock.empty 2 |>.reserve 2).isOk
