import tests.domain.PostPart1
open LeanApp.Domain
inductive ExportError where
  | notFound
-- The post's forgotten check: `Party.guests` demands the proof.
def exportGuests (me : SignedIn) (party : Ref Party) : Op ExportError (List Guest) := do
  let some p ← Party.find party | throw .notFound
  let viewer ← Viewer.of (some me) p
  let guests : List Guest ← Party.guests p viewer
  return guests
