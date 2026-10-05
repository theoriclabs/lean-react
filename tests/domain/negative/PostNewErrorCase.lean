import tests.domain.PostPart1
open LeanApp.Domain
-- The handler was exhaustive for the published RescheduleError. A new rule adds a case:
inductive RescheduleError' where
  | notFound
  | notHost
  | alreadyStarted
  | dateInPast
  | tooClose
def message : RescheduleError' → String
  | .notFound => "No such party."
  | .notHost => "Only the host can reschedule."
  | .alreadyStarted => "The party has started."
  | .dateInPast => "Pick a time in the future."
