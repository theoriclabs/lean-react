import LeanApp.Domain
open LeanApp.Domain
inductive Payload where
  | item (name : Name)
  deriving Domain
