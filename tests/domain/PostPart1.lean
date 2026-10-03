/- The Part 1 post's domain and API code, as far as the portable layer reaches
   (DDD-LR-05, portable halves of DDD-LDB-05 and DDD-LAPI-05).

   Applied coordination decisions: checked scalars `Name`/`Title`/`Text` (7), `getParty` is a
   `ReadOp` (3), `Ref` instead of `Id` (11), the composite `Rsvp` lookup is private (13),
   time-dependent rules take `Now` (14). Auth (`signUp`/`signIn`/`Credential`) is DDD-LAPI-06;
   `SignedIn` is the post's own structure, registered with `deriving Principal`.
   Top level on purpose: `#check Person.insert` must print as in the post. -/
import LeanApp.Domain
open LeanApp.Domain

-- Rule proofs are carried as arguments that the body never inspects.
set_option linter.unusedVariables false

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

/-- info: Person.insert : Person → DB (Except Person.Conflict (Ref Person)) -/
#guard_msgs in #check Person.insert

/--
info: inductive Person.Conflict where
  | uniqueEmail
-/
#guard_msgs in #print Person.Conflict

/-- info: Party.insert : Party → DB (Ref Party) -/
#guard_msgs in #check Party.insert

/-- info: Party.find : Ref Party → Query (Option (Row Party)) -/
#guard_msgs in #check Party.find

/-- info: Person.findBy : Email → Query (Option (Row Person)) -/
#guard_msgs in #check Person.findBy

/-- info: Rsvp.findBy : Ref Party → Ref Person → Query (Option (Row Rsvp)) -/
#guard_msgs in #check Rsvp.findBy

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

derive_operation createPerson
derive_operation edit
derive_operation hostPartyAs
derive_operation rsvpAs
derive_operation reschedule
derive_operation hostThenFail
derive_operation rsvpOrNote

-- An entry with path parameters takes them in path order (Views: `call (api.rsvp party)`).
/-- info: api.rsvp (party : Ref Party) : Endpoint rsvp.Input RsvpError Unit -/
#guard_msgs in #check api.rsvp

/-- info: api.getParty (party : Ref Party) : Endpoint getParty.Input GetPartyError PartyPage -/
#guard_msgs in #check api.getParty

/-- info: api.signUp : Endpoint signUp.Input SignUpError Session -/
#guard_msgs in #check api.signUp

/-- info: api : Api -/
#guard_msgs in #check api

/--
info: @rsvp.flowWithResources : {resources : ResourceFamily} →
  rsvp.Requirements resources →
    {Scope : Type} → _root_.SignedIn → Ref Party → Flow Contract.OperationKind.command Scope RsvpError Unit resources
-/
#guard_msgs in #check @rsvp.flowWithResources

/--
info: @getParty.Requirements.infer : {resources : ResourceFamily} →
  [capability0 : HasEntityResource resources Party] →
    [capability1 : HasEntityResource resources Rsvp] →
      [capability2 : HasEntityResource resources Person] →
        [capability3 :
            HasUniqueResource resources Rsvp (Ref Party × Ref Person) HasEntityResource.witness Rsvp.onePerGuest.key] →
          [capability4 : HasLinkResource resources Rsvp Party Person HasEntityResource.witness Rsvp.link.party.guest] →
            [capability5 : HasColumnResource resources Person Name HasEntityResource.witness Person.namePath] →
              getParty.Requirements resources
-/
#guard_msgs in #check @getParty.Requirements.infer

-- The contract is the ordinary `Contract.Operation`; the error schema is the authored type.
#guard (reschedule.operation.metadata.failures == ["notFound", "notHost", "alreadyStarted", "dateInPast"])
-- Inspect metadata is read off the typed storage calls of the elaborated body.
#guard (reschedule.operation.metadata.nodes.map fun node => (node.kind, node.detail, node.failure)) ==
  [("find", "Party", none), ("findBy", "Rsvp", none), ("now", "", none), ("require", "", some "notHost"),
   ("require", "", some "alreadyStarted"), ("require", "", some "dateInPast"), ("update", "Party", none),
   ("throw", "", some "notFound")]
#guard ((createPerson.operation.metadata.nodes.find? (·.kind == "insert")).map (·.constraints)) == some ["Person.uniqueEmail"]
#guard (createPerson.operation.metadata.nodes.map (·.effect)).contains .command
#guard (rsvp.operation.metadata.actor == "_root_.SignedIn")
#guard (getParty.operation.contract.kind == .query)
#guard (hostPartyAs.operation.metadata.failures == [])
-- The author owns the error type: catching (or deleting) every `throw` keeps its cases.
#guard (rsvpOrNote.operation.metadata.failures == ["notFound", "alreadyStarted"])
#guard (hostPartyAs.operation.contract.describe.error ==
  .named { packageName := "lean", name := "Empty" } "1" (.variant []))
#guard ((api.map (fun e => (e.method.name, e.path))) ==
  [("POST", "/sign-up"), ("POST", "/sign-in"), ("POST", "/parties"), ("GET", "/parties/:party"), ("POST", "/parties/:party/rsvp"),
   ("POST", "/parties/:party/cancel")])
-- Decision 8: the cascade is registered for LeanDB (`Deriving.cascadeDeclarations`), and the
-- generated delete removes the children first.
#guard (cancel.operation.metadata.nodes.map (·.kind)).contains "delete"

/-! ## Proof-carrying access (DDD-LDB-06, portable half) -/

/-- info: Party.patch : Row Party → Party.Changes → DB Unit -/
#guard_msgs in #check Party.patch
#guard (HasRecord.fieldMetadata (T := Party.Changes)).map (·.name) == ["title", "description", "guestList"]
/-- info: Rsvp.link.party.guest : LinkKey Rsvp Party Person -/
#guard_msgs in #check Rsvp.link.party.guest
#guard Rsvp.link.party.guest.identity == "Rsvp.party.guest"
-- The guest list is one join request; no raw RSVP read is reachable from `getParty`.
#guard (getParty.operation.metadata.nodes.map (·.kind)).contains "linkField"
#guard !(getParty.operation.metadata.nodes.map (·.kind)).contains "select"

/-! ## Authentication: KDF steps are hoistable, sessions are marked -/

/-- info: LeanApp.Domain.PasswordHash : Type -/
#guard_msgs in #check PasswordHash
/-- info: Credential.verify {ε : Type} : Option (Row Person) → Password → Op ε (Option (Ref Person)) -/
#guard_msgs in #check Credential.verify
#guard signUp.operation.metadata.kdf == [.hash "password"]
#guard signIn.operation.metadata.kdf == [.verify "password"]
#guard signUp.operation.metadata.establishesSession && signIn.operation.metadata.establishesSession
#guard !rsvp.operation.metadata.establishesSession && rsvp.operation.metadata.kdf == []
#guard (signUp.operation.metadata.nodes.map (·.kind)).contains "hashPassword"
#guard (api.getParty.endpoint.pathParams == ["party"])
-- `api.rsvp party` binds the path field to its public wire value (a bare integer).
#guard match (Ontology.Wire.codec (α := Ref Party)).decode (.num 7) with
  | .ok party => ((api.rsvp party).bound.map fun (name, value) => (name, value.compress)) == [("party", "7")] &&
      (api.rsvp party).concretePath == "/parties/7/rsvp"
  | .error _ => false
