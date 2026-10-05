import LeanApp.Domain
open LeanApp.Domain
structure Dependent (n : Nat) where
  value : Fin n
  deriving Domain
