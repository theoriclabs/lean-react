import tests.domain.PostPart1
open LeanApp.Domain
-- The raw RSVP table is internal to the domain module (DDD-LDB-06).
def everyone : Query (List (Row Rsvp)) := Rsvp.select
