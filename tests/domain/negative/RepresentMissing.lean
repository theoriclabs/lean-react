/- A private-constructor type from another module without `represent` still cannot be a field. -/
import tests.domain.RepresentTypes
import LeanApp.Core
open LeanApp.Core

structure Vault where
  label  : Name
  secret : Opaque
  deriving Entity
