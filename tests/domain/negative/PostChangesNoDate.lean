import tests.domain.PostPart1
open LeanApp.Domain
-- An edit cannot move the party: `Party.Changes` has no `date`.
def sneaky (title : Title) (description : Text) (date : Time) : Party.Changes :=
  { title, description, guestList := .everyone, date }
