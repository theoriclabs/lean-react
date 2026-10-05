import LeanApp.Domain
open LeanApp.Domain
command% impossible (date : Instant) : Unit := do
  require date > now else future
  let reversed : date < now := by omega
  pure ()
