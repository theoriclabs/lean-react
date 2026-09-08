import Ordering
open Ordering
def rejected (s : Stock) : Stock := { s with reserved := s.capacity + 1 }
