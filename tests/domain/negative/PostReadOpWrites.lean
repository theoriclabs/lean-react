import tests.domain.PostPart1
open LeanApp.Domain
def sneaky (me : SignedIn) (title : Title) (description : Text) (date : Time) : ReadOp Empty (Ref Party) := do
  Party.insert { host := me.id, title, description, date, guestList := .everyone }
