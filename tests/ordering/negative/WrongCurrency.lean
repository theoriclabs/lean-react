import Ordering
open Ordering
def rejected (usd : Money .usd) (eur : Money .eur) : Money .usd := usd.add eur
