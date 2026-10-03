/- Domain authoring acceptance fixture; compiles against the local library changes.
   Native app assembly is tracked in ../runs/partiful/STATUS.md. -/
import LeanApp.Domain

open LeanApp.Domain
namespace Partiful

inductive GuestListVisibility where
  | «public» | attendees | «private»
  deriving Domain

@[entity] structure Person where
  name : Name
  email : Email

unique% Person.byEmail := email

@[entity] structure Party where
  host : Ref Person
  title : Title
  date : Instant
  description : Text
  visibility : GuestListVisibility := .public
  guests : Members Person := {}

auth% account : Person using emailPassword(email)

policy% canSeeGuests (viewer : Viewer Person) (party : Row Party) :=
  match party.visibility with
  | .public => true
  | .attendees => viewer.person.any party.guests.contains
  | .private => false

command% host (me : SignedIn Person)
    (title : Title) (date : Instant) (description : Text)
    (visibility : GuestListVisibility := .public) : Ref Party := do
  require date > now else dateMustBeFuture
  create Party { host := me.id, title, date, description, visibility }

command% rsvp (me : SignedIn Person) (id : Ref Party) : Unit := do
  let party ← find Party id else partyMissing
  require now < party.date else partyStarted
  include me.id in party.guests

command% edit (me : SignedIn Person) (id : Ref Party)
    (title : Title) (description : Text)
    (visibility : GuestListVisibility) : Unit := do
  let party ← find Party id else partyMissing
  require me.id == party.host else hostOnly
  change party { title, description, visibility }

command% reschedule (me : SignedIn Person) (id : Ref Party)
    (date : Instant) : Unit := do
  let party ← find Party id else partyMissing
  require me.id == party.host else hostOnly
  require now < party.date else partyStarted
  require now < date else dateMustBeFuture
  change party { date }

command% cancel (me : SignedIn Person) (id : Ref Party) : Unit := do
  let party ← find Party id else partyMissing
  require me.id == party.host else hostOnly
  remove party

structure Guest where
  name : Name
  deriving Domain

structure PartyPage where
  title : Title
  date : Instant
  description : Text
  visibility : GuestListVisibility
  guests : Disclosure (List Guest)
  deriving Domain

query% partyPage (viewer : Viewer Person) (id : Ref Party) : PartyPage := do
  let party ← find Party id else partyMissing
  let guests ← disclose (canSeeGuests viewer party) do
    party.guests.project fun person => Guest.mk person.name
  return { title := party.title, date := party.date,
           description := party.description, visibility := party.visibility, guests }

end Partiful
