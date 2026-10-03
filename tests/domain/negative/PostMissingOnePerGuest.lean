import LeanApp.Domain
open LeanApp.Domain
structure Person where
  name : Name
  deriving Entity
structure Party where
  title : Title
  deriving Entity
structure Rsvp where
  party : Ref Party
  guest : Ref Person
  deriving Entity
constraint Rsvp.onePerGuest : unique (party, guest)
inductive RsvpError where
  | notFound
def rsvp (guest : Ref Person) (party : Ref Party) : Op RsvpError Unit := do
  let some _ ← Party.find party | throw .notFound
  match ← Rsvp.insert { party, guest } with
  | .ok _ => pure ()
