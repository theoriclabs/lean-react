import tests.domain.PostPart1
open LeanApp.Domain
-- The composite RSVP lookup is private to the domain module (decision 13).
def probe (party : Ref Party) (person : Ref Person) := Rsvp.findBy party person
