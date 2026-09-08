import Ordering
open Ordering
def rejected (cancelled : Order .usd .cancelled) (receipt : Receipt .usd) :
    Except PaymentError (Order .usd .paid) := cancelled.pay receipt
