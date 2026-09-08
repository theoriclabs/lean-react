import Ordering
open Ordering
def rejected (placed : Order .usd .placed) (receipt : Receipt .usd) := do
  let paid ← placed.pay receipt
  paid.pay receipt
