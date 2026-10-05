import LeanApp.Domain
open LeanApp.Domain
namespace PartifulFlows
inductive Visibility where
  | «public» | attendees | «private»
  deriving Domain
@[entity] structure Person where
  name : Name
  email : Email
unique% Person.byEmail := email
auth% account : Person using emailPassword(email)
@[entity] structure Party where
  host : Ref Person
  title : Title
  date : Instant
  description : Text
  visibility : Visibility := .public
  guests : Members Person := {}
command% host (me : SignedIn Person) (title : Title) (date : Instant)
    (description : Text) (visibility : Visibility := .public) : Ref Party := do
  require date > now else dateMustBeFuture
  create Party { host := me.id, title, date, description, visibility }
command% rsvp (me : SignedIn Person) (id : Ref Party) : Unit := do
  let party ← find Party id else partyMissing
  require now < party.value.date else partyStarted
  include me.id in party.guests
command% edit (me : SignedIn Person) (id : Ref Party) (title : Title)
    (description : Text) (visibility : Visibility) : Unit := do
  let party ← find Party id else partyMissing
  require me.id == party.value.host else hostOnly
  change party { title, description, visibility }
command% reschedule (me : SignedIn Person) (id : Ref Party) (date : Instant) : Unit := do
  let party ← find Party id else partyMissing
  require me.id == party.value.host else hostOnly
  require now < party.value.date else partyStarted
  require now < date else dateMustBeFuture
  change party { date }
command% cancel (me : SignedIn Person) (id : Ref Party) : Unit := do
  let party ← find Party id else partyMissing
  require me.id == party.value.host else hostOnly
  remove party
structure Guest where
  name : Name
  deriving Domain, BEq, Repr
structure PartyPage where
  title : Title
  date : Instant
  description : Text
  visibility : Visibility
  guests : Disclosure (List Guest)
  deriving Domain
policy% canSeeGuests (viewer : Viewer Person) (party : Row Party) :=
  match party.value.visibility with
  | .public => .literal true
  | .attendees => .viewerMember viewer (party.membersField "guests")
  | .private => .literal false
query% partyPage (viewer : Viewer Person) (id : Ref Party) : PartyPage := do
  let party ← find Party id else partyMissing
  let guests ← Flow.disclose (canSeeGuests viewer party)
    ((Projection.memberField (party.membersField "guests") "name").map (List.map Guest.mk))
  return { title := party.value.title, date := party.value.date, description := party.value.description, visibility := party.value.visibility, guests := guests }
#check host
#check rsvp
#check edit
#check reschedule
#check cancel
#check partyPage
#eval reschedule.metadata.failures
end PartifulFlows

#check PartifulFlows.account.signUp
#check PartifulFlows.account.signUp.Error.emailTaken
#check PartifulFlows.account.signIn.Error.invalidCredentials
