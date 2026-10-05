/- The clean domain surface (`import LeanApp.Core`): the post's domain and pages written with
   their own `SignedIn` and `Viewer`, which print without `_root_` because no milestone-1 names
   are in scope. Pages use `import LeanReact.Domain` and `open LeanReact`. -/
import LeanApp.Core
import LeanReact.Domain
open LeanApp.Core LeanReact

namespace CleanSurface

/-! ## What exists -/

structure Person where
  name  : Name
  email : Email
  deriving Entity

inductive GuestListVisibility where
  | everyone    -- anyone with the link
  | attendees   -- the host and people who RSVP'd
  | hostOnly    -- just the host

structure Party where
  host        : Ref Person
  title       : Title
  description : Text
  date        : Time
  guestList   : GuestListVisibility
  deriving Entity

structure Rsvp where
  party : Ref Party
  guest : Ref Person
  deriving Entity

-- DDD-LDB-06: the raw RSVP table is read and written only in this module (`Party.guests`,
-- `Rsvp.add`), raw party writes too, and an edit cannot touch the host or the date.
internal Rsvp.select, Rsvp.insert, Party.update, Party.delete
-- The guest list joins RSVPs to the people who sent them.
link Rsvp.party Rsvp.guest
deriving instance Changes (except := [host, date]) for Party

constraint Person.uniqueEmail : unique email
private constraint Rsvp.onePerGuest : unique (party, guest)
-- Decision 8: deleting a party deletes its RSVPs.
constraint Rsvp.cancelWithParty : cascade party
-- Generated on first use anyway; listed so importing modules can rely on them.
entity_operations Person, Party, Rsvp







/-! ## What people can do (first version: ids in the request) -/

def hostPartyAs (host : Ref Person) (title : Title) (description : Text) (date : Time)
    (guestList : GuestListVisibility) : Op Empty (Ref Party) :=
  Party.insert { host, title, description, date, guestList }

inductive FirstRsvpError where
  | notFound

def rsvpAs (guest : Ref Person) (party : Ref Party) : Op FirstRsvpError Unit := do
  let some _ ← Party.find party | throw .notFound
  match ← Rsvp.insert { party, guest } with
  | .ok _               => pure ()
  | .error .onePerGuest => pure ()  -- already going

/-! ## An API -/

inductive CreatePersonError where
  | emailTaken

def createPerson (name : Name) (email : Email) :
    Op CreatePersonError (Ref Person) := do
  match ← Person.insert { name, email } with
  | .ok id              => pure id
  | .error .uniqueEmail => throw .emailTaken

/-! ## Anyone can be anyone -/

structure SignedIn where
  private mk ::
  id : Ref Person
  deriving Principal

/-! ### Sign up and sign in (DDD-LAPI-06): `Credential` is app code -/

structure Credential where
  person : Ref Person
  hash   : PasswordHash
  deriving Entity

-- Explicit opt-in: generates `Credential.verify`.
credential Credential.person Credential.hash

inductive SignUpError where
  | emailTaken

def signUp (name : Name) (email : Email) (password : Password) :
    Op SignUpError Session := do
  match ← Person.insert { name, email } with
  | .error .uniqueEmail => throw .emailTaken
  | .ok id =>
    let _ ← Credential.insert { person := id, hash := ← password.hash }
    Auth.startSession id

inductive SignInError where
  | wrongEmailOrPassword

-- Decision 2: `verify` takes the lookup result as is and does the same work for `none`.
def signIn (email : Email) (password : Password) : Op SignInError Session := do
  let some id ← Credential.verify (← Person.findBy email) password
    | throw .wrongEmailOrPassword
  Auth.startSession id

/-! ## Who can see who's coming -/

inductive Role where
  | host
  | attendee
  | visitor   -- signed in or not, hasn't RSVP'd
  deriving DecidableEq, Repr

structure Viewer (party : Ref Party) where
  private mk ::
  role : Role

/-- Your role relative to one party, from your session and the RSVP table. -/
def Viewer.of (session : Option SignedIn) (p : Row Party) : Query (Viewer p.id) := do
  match session with
  | none => return ⟨.visitor⟩
  | some me =>
    if me.id == p.host then return ⟨.host⟩
    match ← Rsvp.findBy p.id me.id with
    | some _ => return ⟨.attendee⟩
    | none => return ⟨.visitor⟩

def CanSeeGuests : GuestListVisibility → Role → Bool
  | .everyone,  _         => true
  | .attendees, .host     => true
  | .attendees, .attendee => true
  | .attendees, .visitor  => false
  | .hostOnly,  .host     => true
  | .hostOnly,  .attendee => false
  | .hostOnly,  .visitor  => false

structure Guest where
  name : Name

inductive GuestList where
  | visible (guests : List Guest)
  | hidden

structure PartyPage where
  title       : Title
  description : Text
  date        : Time
  guests      : GuestList

inductive GetPartyError where
  | notFound

/-- Names of the people who RSVP'd, by guest id: one typed join (RSVP ⋈ Person) that selects
only `name`. It takes the proof that this viewer may see them. -/
def Party.guests (p : Row Party) (viewer : Viewer p.id)
    (h : CanSeeGuests p.guestList viewer.role) : Query (List Guest) :=
  (·.map Guest.mk) <$> Query.linkField Rsvp.link.party.guest Person.namePath p.id

def getParty (session : Option SignedIn) (party : Ref Party) :
    ReadOp GetPartyError PartyPage := do
  let some p ← Party.find party | throw .notFound
  let viewer ← Viewer.of session p
  let guests ←
    if h : CanSeeGuests p.guestList viewer.role then
      GuestList.visible <$> Party.guests p viewer h
    else
      pure .hidden
  return { title := p.title, description := p.description, date := p.date, guests }

/-! ## The rest of the rules -/

/-- Only the host can edit or cancel a party. -/
def MayEdit (p : Row Party) (viewer : Viewer p.id) : Prop :=
  viewer.role = .host

/-- Nobody can RSVP once the party has started. -/
def MayRsvp (now : Now) (p : Row Party) : Prop :=
  now < p.date

/-- A party can be moved until it starts, and only to a time in the future. -/
def MayReschedule (now : Now) (p : Row Party) (date : Time) : Prop :=
  now < p.date ∧ now < date

/-- The only way to change a date. (DDD-LDB-06 makes the raw `Party.update` private.) -/
def Party.reschedule (p : Row Party) (viewer : Viewer p.id) (now : Now) (date : Time)
    (h₁ : MayEdit p viewer) (h₂ : MayReschedule now p date) : DB Unit :=
  Party.update p { p.toParty with date }

/-- Only the host edits, and an edit cannot change the date or the host. -/
def Party.edit (p : Row Party) (viewer : Viewer p.id) (changes : Party.Changes)
    (h : MayEdit p viewer) : DB Unit :=
  Party.patch p changes

/-- `Rsvp.cancelWithParty` deletes the party's RSVPs with it. -/
def Party.cancel (p : Row Party) (viewer : Viewer p.id) (h : MayEdit p viewer) : DB Unit :=
  Party.delete p

/-- RSVP as yourself, before the party starts. -/
def Rsvp.add (p : Row Party) (me : SignedIn) (now : Now)
    (h : MayRsvp now p) : DB (Except Rsvp.Conflict Unit) := do
  match ← Rsvp.insert { party := p.id, guest := me.id } with
  | .ok _ => return .ok ()
  | .error conflict => return .error conflict

inductive HostError where
  | dateInPast

def hostParty (me : SignedIn) (title : Title) (description : Text) (date : Time)
    (guestList : GuestListVisibility) : Op HostError (Ref Party) := do
  let now ← Clock.now
  let ⟨_⟩ ← require (now < date) .dateInPast
  Party.insert { host := me.id, title, description, date, guestList }

inductive RsvpError where
  | notFound
  | alreadyStarted

def rsvp (me : SignedIn) (party : Ref Party) : Op RsvpError Unit := do
  let some p ← Party.find party | throw .notFound
  let now ← Clock.now
  let ⟨isOpen⟩ ← require (MayRsvp now p) .alreadyStarted
  match ← Rsvp.add p me now isOpen with
  | .ok _               => pure ()
  | .error .onePerGuest => pure ()  -- already going

inductive RescheduleError where
  | notFound
  | notHost
  | alreadyStarted
  | dateInPast

def reschedule (me : SignedIn) (party : Ref Party) (date : Time) :
    Op RescheduleError Unit := do
  let some p ← Party.find party | throw .notFound
  let viewer ← Viewer.of (some me) p
  let now ← Clock.now
  let ⟨isHost⟩     ← require (MayEdit p viewer) .notHost
  let ⟨notStarted⟩ ← require (now < p.date) .alreadyStarted
  let ⟨inFuture⟩   ← require (now < date) .dateInPast
  Party.reschedule p viewer now date isHost ⟨notStarted, inFuture⟩

inductive EditError where
  | notFound
  | notHost

def edit (me : SignedIn) (party : Ref Party) (changes : Party.Changes) : Op EditError Unit := do
  let some p ← Party.find party | throw .notFound
  let viewer ← Viewer.of (some me) p
  let ⟨isHost⟩ ← require (MayEdit p viewer) .notHost
  Party.edit p viewer changes isHost

inductive CancelError where
  | notFound
  | notHost

def cancel (me : SignedIn) (party : Ref Party) : Op CancelError Unit := do
  let some p ← Party.find party | throw .notFound
  let viewer ← Viewer.of (some me) p
  let ⟨isHost⟩ ← require (MayEdit p viewer) .notHost
  Party.cancel p viewer isHost

/-- A late error after a write: the whole operation rolls back. (Runtime fixture.) -/
def hostThenFail (me : SignedIn) (title : Title) (description : Text) (date : Time) :
    Op HostError Unit := do
  let _ ← Party.insert { host := me.id, title, description, date, guestList := .everyone }
  throw .dateInPast

/-- `try … catch` in plain `do`: a caught failure is a value. (Runtime fixture.) -/
def rsvpOrNote (me : SignedIn) (party : Ref Party) : Op RsvpError String := do
  try
    rsvp me party
    pure "going"
  catch
    | .notFound => pure "no such party"
    | .alreadyStarted => pure "too late"

/-! ## Publishing: endpoints read off the function types -/

def api : Api := [
  post "/sign-up"             signUp,
  post "/sign-in"             signIn,
  post "/parties"             hostParty,
  get  "/parties/:party"      getParty,
  post "/parties/:party/rsvp" rsvp,
  post "/parties/:party/cancel" cancel
]


/-! ## The app's own names print plainly -/

/-- info: CleanSurface.Viewer.of (session : Option SignedIn) (p : Row Party) : Query (Viewer p.id) -/
#guard_msgs in #check Viewer.of

/-- info: CleanSurface.Party.find : Ref Party → Query (Option (Row Party)) -/
#guard_msgs in #check Party.find

/-- info: CleanSurface.api.rsvp (party : Ref Party) : Endpoint rsvp.Input RsvpError Unit -/
#guard_msgs in #check api.rsvp

/-! ## Pages -/

def signUpPage : Element :=
  form api.signUp
    (onSuccess := fun _ => navigate "/")
    (onError := fun
      | .emailTaken => fieldError "email" "This email already has an account. Sign in instead?")

def guestsView : GuestList → Element
  | .visible guests => DOM.ul {} (guests.map fun g => DOM.li {} #[text g.name]).toArray
  | .hidden => DOM.p {} #[text "The host is keeping the guest list private."]

def partyView (page : PartyPage) (onRsvp : Action Unit) : Element :=
  DOM.div {} #[
    DOM.h1 {} #[text page.title],
    DOM.p {} #[text page.date.format],
    DOM.p {} #[text page.description],
    DOM.button { onPress := some onRsvp } #[text "I'm going"],
    guestsView page.guests
  ]

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party)
    (onSuccess := fun _ => pure ())
    (onError := fun
      | .notFound       => notice "This party no longer exists."
      | .alreadyStarted => notice "This party has already started.")

def partyPage (party : Ref Party) : Element :=
  load (api.getParty party)
    (onError := fun | .notFound => DOM.p {} #[text "This party doesn't exist."])
    fun page => partyView page (rsvpButton party)

def app : App where
  api   := api
  pages := [ "/sign-up" ==> signUpPage, "/parties/:party" ==> partyPage ]

/-! ## Displaying checked scalars and times -/

#guard (match Name.parse "Asha", Instant.ofEpochSeconds 1792263600 with
  | .ok name, .ok time => toString name == "Asha" && s!"{name} at {time}" == "Asha at 2026-10-17 19:00 UTC" &&
      Time.format time == "2026-10-17 19:00 UTC" && ((name : String) == "Asha")
  | _, _ => false)
#guard (match Instant.ofEpochSeconds 1792263605 with | .ok t => t.format == "2026-10-17 19:00:05 UTC" | .error _ => false)

end CleanSurface
