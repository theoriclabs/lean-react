/- Runs the Part 1 post's plain operations on the portable Memory backend, with populated
   state, and runs their PUBLISHED, resource-generic bodies through a non-portable resource
   family whose witnesses are checked at every storage request. -/
import tests.domain.PostPart1
import LeanApp.Domain.Memory
open LeanApp.Domain Ontology

namespace PostPart1Run

private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw (IO.userError ("FAIL: " ++ label))
private def ok [Repr E] (value : Except E A) : IO A :=
  match value with | .ok value => pure value | .error error => throw (IO.userError (reprStr error))
private def parsed (value : Validation A) : IO A :=
  match value with | .ok value => pure value | .error _ => throw (IO.userError "fixture value rejected")
private def instant (seconds : Int) : IO Time := parsed (Instant.ofEpochSeconds seconds)

/-- Run a read-write operation: one transaction, rolled back on a domain error. -/
private def run (op : Op ε α) (store : Memory.Store) : IO (Except ε α × Memory.Store) :=
  ok (Memory.command (op : Flow .command OpScope ε α) store)
/-- Run a read-only operation on a snapshot. -/
private def read (op : ReadOp ε α) (store : Memory.Store) : IO (Except ε α) := do
  let (result, _) ← ok (Memory.read (op : Flow .query OpScope ε α) store)
  return result
private def value [Repr ε] (result : Except ε α × Memory.Store) : IO (α × Memory.Store) := do
  return (← ok result.1, result.2)
private def failsWith [BEq ε] (result : Except ε α) (expected : ε) : Bool :=
  match result with | .error error => error == expected | .ok _ => false

deriving instance BEq, Repr for CreatePersonError
deriving instance BEq, Repr for FirstRsvpError
deriving instance BEq, Repr for HostError
deriving instance BEq, Repr for RsvpError
deriving instance BEq, Repr for RescheduleError
deriving instance BEq, Repr for GetPartyError
deriving instance BEq, Repr for CancelError

/-- The session layer is DDD-LAPI-06; tests build actors through the trusted adapter API. -/
private def signedIn (store : Memory.Store) (id : Ref Person) : IO SignedIn := do
  let (row, _) ← ok ((Memory.lookup (Scope := OpScope) id).run store)
  match row with
  | some row => pure (Principal.trusted row.id row.value)
  | none => throw (IO.userError "no such person")

private def guestNames (page : PartyPage) : Option (List String) :=
  match page.guests with
  | .visible guests => some (guests.map (·.name.value))
  | .hidden => none

private def rows (store : Memory.Store) (entity : String) : Nat :=
  (store.rows.filter (·.1.entity.name == entity)).length

def plainOperations : IO Unit := do
  let initial : Memory.Store := { now := ← instant 1000 }
  let asha ← parsed (Name.parse "Asha")
  let ben ← parsed (Name.parse "Ben")
  let ashaEmail ← parsed (Email.parse "asha@example.com")
  let (ashaId, store) ← value (← run (createPerson asha ashaEmail) initial)
  let (benId, store) ← value (← run (createPerson ben (← parsed (Email.parse "ben@example.com"))) store)
  check "two people" (rows store "Person" == 2)
  -- The constraint's conflict is a value the operation maps to its own error.
  let (taken, unchanged) ← run (createPerson (← parsed (Name.parse "Not Asha")) (← parsed (Email.parse " ASHA@Example.COM "))) store
  check "duplicate (canonical) email is emailTaken" (failsWith taken .emailTaken)
  check "conflict leaves state unchanged" (unchanged.rows == store.rows)
  let asha ← signedIn store ashaId
  let ben ← signedIn store benId
  let title ← parsed (Title.parse "Housewarming")
  let description ← parsed (Text.parse "Bring a plant")
  let future ← instant 5000
  -- First version: `Op Empty`, the id comes from the request.
  let (firstParty, store) ← value (← run (hostPartyAs ashaId title description future .everyone) store)
  -- Rules take the server's `Now`; a past date is the authored error.
  let (past, _) ← run (hostParty asha title description (← instant 10) .everyone) store
  check "host in the past is dateInPast" (failsWith past .dateInPast)
  let (party, store) ← value (← run (hostParty asha title description future .everyone) store)
  check "parties get distinct ids" (party.key != firstParty.key)
  let (attendeesParty, store) ← value (← run (hostParty asha title description future .attendees) store)
  let (privateParty, store) ← value (← run (hostParty asha title description future .hostOnly) store)
  -- RSVP: idempotent through the named conflict.
  let (_, store) ← value (← run (rsvp ben party) store)
  let (again, store) ← value (← run (rsvp ben party) store)
  check "second yes is fine" (again == ())
  check "one RSVP row per guest" (rows store "Rsvp" == 1)
  let (_, store) ← value (← run (rsvp ben attendeesParty) store)
  let (_, store) ← value (← run (rsvp ben privateParty) store)
  let missing ← parsed (Ref.parse (T := Party) "999")
  let (noParty, _) ← run (rsvp ben missing) store
  check "rsvp to a missing party" (failsWith noParty .notFound)
  let started := { store with now := future }
  let (late, _) ← run (rsvp asha party) started
  check "no RSVP once started (exact cutoff)" (failsWith late .alreadyStarted)
  -- First-version RSVP shares the same constraint.
  let (_, store) ← value (← run (rsvpAs ashaId firstParty) store)
  let (_, store) ← value (← run (rsvpAs ashaId firstParty) store)
  check "first-version rsvp also one row per guest" (rows store "Rsvp" == 4)
  -- Guest-list visibility matrix: visitor / attendee / host for each setting.
  let visitor : Option SignedIn := none
  let expectations : List (Ref Party × List (Option SignedIn × Option (List String))) := [
    (party, [(visitor, some ["Ben"]), (some ben, some ["Ben"]), (some asha, some ["Ben"])]),
    (attendeesParty, [(visitor, none), (some ben, some ["Ben"]), (some asha, some ["Ben"])]),
    (privateParty, [(visitor, none), (some ben, none), (some asha, some ["Ben"])])]
  for (target, cases) in expectations do
    for (session, expected) in cases do
      let page ← ok (← read (getParty session target) store)
      check "visibility matrix" (guestNames page == expected)
  let page ← ok (← read (getParty none party) store)
  check "party page fields" (page.title.value == "Housewarming" && page.date == future)
  check "empty and hidden differ" (guestNames { page with guests := .visible [] } != guestNames { page with guests := .hidden })
  let pageMissing ← read (getParty none missing) store
  check "getParty notFound" (failsWith pageMissing .notFound)
  -- Reschedule: lookup, host, started, future — each its own error, in order.
  let later ← instant 9000
  let (r1, _) ← run (reschedule ben missing later) store
  check "reschedule missing" (failsWith r1 .notFound)
  let (r2, _) ← run (reschedule ben party later) store
  check "only the host reschedules" (failsWith r2 .notHost)
  let (r3, _) ← run (reschedule asha party later) started
  check "not after the start" (failsWith r3 .alreadyStarted)
  let (r4, _) ← run (reschedule asha party (← instant 999)) store
  check "only to the future" (failsWith r4 .dateInPast)
  let (_, moved) ← value (← run (reschedule asha party later) store)
  let movedPage ← ok (← read (getParty none party) moved)
  check "rescheduled date persisted" (movedPage.date == later)
  check "reschedule keeps RSVPs" (guestNames movedPage == some ["Ben"])
  -- A late domain error rolls back the write before it.
  let (rolled, after) ← run (hostThenFail asha title description future) store
  check "late error" (failsWith rolled .dateInPast)
  check "rollback on late error" (after.rows == store.rows && rows after "Party" == rows store "Party")
  -- try/catch: a caught failure becomes a value.
  let (note, _) ← value (← run (rsvpOrNote ben missing) store)
  check "caught notFound" (note == "no such party")
  let (note, _) ← value (← run (rsvpOrNote ben party) started)
  check "caught alreadyStarted" (note == "too late")
  let (note, _) ← value (← run (rsvpOrNote asha party) store)
  check "uncaught success" (note == "going")
  IO.println "PASS plain Op/ReadOp on Memory: constraints as values, visibility matrix, rules with Now, rollback, try/catch"

/-! ## PublishedOperation bodies are resource-generic -/

/-- A non-portable family: each witness names its entity / constraint. -/
def tagged : ResourceFamily := {
  entity := fun _ => ULift String
  member := fun _ _ _ => PUnit
  projection := fun _ _ => PUnit
  auth := fun _ => PUnit
  unique := fun _ _ => ULift String
  link := fun _ _ => ULift String
  column := fun _ _ => ULift String }

instance : HasEntityResource tagged Person := ⟨⟨"Person"⟩⟩
instance : HasEntityResource tagged Party := ⟨⟨"Party"⟩⟩
instance : HasEntityResource tagged Rsvp := ⟨⟨"Rsvp"⟩⟩
instance (storage : tagged.entity Rsvp) : HasUniqueResource tagged Rsvp (Ref Party × Ref Person) storage Rsvp.onePerGuest.key :=
  ⟨⟨"Rsvp.onePerGuest"⟩⟩
instance (storage : tagged.entity Rsvp) : HasLinkResource tagged Rsvp Party Person storage Rsvp.link.party.guest :=
  ⟨⟨"Rsvp.party.guest"⟩⟩
instance (storage : tagged.entity Person) : HasColumnResource tagged Person Name storage Person.namePath :=
  ⟨⟨"Person.name"⟩⟩

private def expect (actual expected : String) : Memory.Engine Unit :=
  unless actual == expected do throw (.unsupportedConstraint s!"witness {actual} used for {expected}")

/-- The witness a request carries must be its own entity's / constraint's. -/
def checkWitness : Request Scope E k A tagged → Memory.Engine Unit
  | @RequestF.find _ _ _ _ T _ storage _ => expect storage.down (HasTypeId.typeId (α := T)).name
  | @RequestF.select _ _ _ _ T _ storage => expect storage.down (HasTypeId.typeId (α := T)).name
  | @RequestF.insert _ _ _ T _ _ storage _ _ => expect storage.down (HasTypeId.typeId (α := T)).name
  | @RequestF.update _ _ _ T _ _ storage _ _ _ => expect storage.down (HasTypeId.typeId (α := T)).name
  | @RequestF.delete _ _ _ T _ storage _ => expect storage.down (HasTypeId.typeId (α := T)).name
  | @RequestF.findBy _ _ _ _ T _ _ storage unique lookup _ => do
      expect storage.down (HasTypeId.typeId (α := T)).name
      expect lookup.down unique.identity
  | @RequestF.linkField _ _ _ _ E _ T _ _ _ edges key link targets _ column _ => do
      expect edges.down (HasTypeId.typeId (α := E)).name
      expect link.down key.identity
      expect targets.down (HasTypeId.typeId (α := T)).name
      expect column.down "Person.name"
  | _ => pure ()

/-- Memory, after checking every request's witness. -/
def taggedRequest (req : Request Scope E k A tagged) : Memory.Engine (Except E A) := do
  checkWitness req
  Memory.request req

def taggedAlgebra : Algebra Memory.Engine k Scope E tagged := ⟨taggedRequest, Memory.contains, Memory.project⟩

def genericBodies : IO Unit := do
  let initial : Memory.Store := { now := ← instant 1000 }
  let (ashaId, store) ← value (← run (createPerson (← parsed (Name.parse "Asha")) (← parsed (Email.parse "asha@example.com"))) initial)
  let (benId, store) ← value (← run (createPerson (← parsed (Name.parse "Ben")) (← parsed (Email.parse "ben@example.com"))) store)
  let asha ← signedIn store ashaId
  let ben ← signedIn store benId
  let input : hostParty.Input := ⟨← parsed (Title.parse "Picnic"), ← parsed (Text.parse ""), ← instant 5000, .attendees⟩
  -- The published operation's portable specialization is the same body as `hostParty`.
  let (party, store) ← value (← ok (Memory.command (hostParty.operation.body (Scope := OpScope) asha input) store))
  -- The SAME bodies under the tagged family, with requirements inferred from instances.
  let rsvpBody := rsvp.flowWithResources (rsvp.Requirements.infer (resources := tagged)) (Scope := Unit) ben party
  let (result, store) ← ok ((Flow.run taggedAlgebra rsvpBody).run store)
  let _ ← ok result
  check "generic rsvp wrote through tagged witnesses" (rows store "Rsvp" == 1)
  let pageBody := getParty.flowWithResources (getParty.Requirements.infer (resources := tagged)) (Scope := Unit) (some ben) party
  let (page, _) ← ok ((Flow.run taggedAlgebra pageBody).run store)
  check "generic getParty (findBy through the unique capability)" (guestNames (← ok page) == some ["Ben"])
  let visitorBody := getParty.flowWithResources (getParty.Requirements.infer (resources := tagged)) (Scope := Unit) none party
  let (hidden, _) ← ok ((Flow.run taggedAlgebra visitorBody).run store)
  check "generic getParty hides from visitors" (guestNames (← ok hidden) == none)
  -- A family whose Party witness is wrong is caught at the request.
  let wrong : getParty.Requirements tagged :=
    ⟨⟨⟨"Person"⟩⟩, ⟨⟨"Rsvp"⟩⟩, ⟨⟨"Person"⟩⟩, ⟨⟨"Rsvp.onePerGuest"⟩⟩, ⟨⟨"Rsvp.party.guest"⟩⟩, ⟨⟨"Person.name"⟩⟩, ⟨⟩⟩
  match (Flow.run taggedAlgebra (getParty.flowWithResources wrong (Scope := Unit) none party)).run store with
  | .error (.unsupportedConstraint message) => check "wrong witness reaches the interpreter" (message.startsWith "witness Person used for Party")
  | _ => throw (IO.userError "FAIL: a mismatched witness was not observed")
  -- The api's typed endpoints carry the same operations.
  let (viaEndpoint, _) ← ok (Memory.command (api.rsvp.endpoint.operation.body (Scope := OpScope) asha ⟨party⟩) store)
  let _ ← ok viaEndpoint
  IO.println "PASS published bodies are resource-generic: requirements inferred, witnesses threaded to every request"

deriving instance BEq, Repr for SignUpError
deriving instance BEq, Repr for SignInError

def authentication : IO Unit := do
  let initial : Memory.Store := { now := ← instant 1000 }
  let password ← parsed (Password.parse "correct horse battery staple")
  let (session, store) ← value (← run (signUp (← parsed (Name.parse "Asha")) (← parsed (Email.parse "asha@example.com")) password) initial)
  check "sign-up starts a session for the new person" (store.sessions == [session.profileKey] && rows store "Credential" == 1)
  check "sign-up hashed once" (store.kdfRuns == 1)
  check "the session's wire form is the profile ref" ((Wire.codec (α := Session)).encode session == .num ⟨1, 0⟩)
  -- One transaction: a duplicate email leaves no person, credential or session behind.
  let (taken, after) ← run (signUp (← parsed (Name.parse "Not Asha")) (← parsed (Email.parse "ASHA@example.com")) password) store
  check "duplicate sign-up is emailTaken" (failsWith taken .emailTaken)
  check "duplicate sign-up rolls back" (after.rows == store.rows && after.sessions == store.sessions)
  let (again, signedIn) ← value (← run (signIn (← parsed (Email.parse "Asha@Example.com")) password) store)
  check "sign-in with the right password" (again.profileKey == session.profileKey && signedIn.sessions.length == 2)
  let wrong ← parsed (Password.parse "wrong horse battery staple")
  let (badPassword, afterBad) ← run (signIn (← parsed (Email.parse "asha@example.com")) wrong) store
  let (unknown, afterUnknown) ← run (signIn (← parsed (Email.parse "nobody@example.com")) password) store
  check "wrong password and unknown email are the same error" (failsWith badPassword .wrongEmailOrPassword && failsWith unknown .wrongEmailOrPassword)
  -- Decision 2: equal KDF work for an unknown email (the dummy verify), no session either way.
  -- (Measured before rollback: Memory discards a failed operation's store, counters included.)
  let work := fun (op : Op SignInError Session) => do
    let (_, raw) ← ok ((Flow.run Memory.algebra (op : Flow .command OpScope SignInError Session)).run store)
    return raw.kdfRuns - store.kdfRuns
  let badWork ← work (signIn (← parsed (Email.parse "asha@example.com")) wrong)
  let unknownWork ← work (signIn (← parsed (Email.parse "nobody@example.com")) password)
  check "same KDF work for unknown email" (badWork == 1 && unknownWork == 1)
  check "no session on failure" (afterBad.sessions == store.sessions && afterUnknown.sessions == store.sessions)
  -- The stored hash is not the password and cannot be published.
  check "stored hash is not the password" (!((store.rows.map (·.2.compress)).any fun row => (row.splitOn password.value).length > 1))
  IO.println "PASS sign-up/sign-in on Memory: session per sign-in, rollback, one error, equal KDF work for unknown email"

deriving instance BEq, Repr for EditError

def proofCarrying : IO Unit := do
  let initial : Memory.Store := { now := ← instant 1000 }
  let person := fun (name email : String) (store : Memory.Store) => do
    value (← run (createPerson (← parsed (Name.parse name)) (← parsed (Email.parse email))) store)
  let (ashaId, store) ← person "Asha" "asha@example.com" initial
  let (benId, store) ← person "Ben" "ben@example.com" store
  let (caraId, store) ← person "Cara" "cara@example.com" store
  let asha ← signedIn store ashaId
  let ben ← signedIn store benId
  let cara ← signedIn store caraId
  let future ← instant 5000
  let (party, store) ← value (← run (hostParty asha (← parsed (Title.parse "Picnic")) (← parsed (Text.parse "")) future .everyone) store)
  -- RSVP out of id order, and twice: the join returns each guest once, by guest id.
  let (_, store) ← value (← run (rsvp cara party) store)
  let (_, store) ← value (← run (rsvp ben party) store)
  let (_, store) ← value (← run (rsvp cara party) store)
  let page ← ok (← read (getParty none party) store)
  check "join: names only, each once, by guest id" (guestNames page == some ["Ben", "Cara"])
  -- Party.Changes has no host or date: an edit changes only the editable fields.
  let changes : Party.Changes := { title := ← parsed (Title.parse "Garden picnic"), description := ← parsed (Text.parse "Bring a blanket"), guestList := .hostOnly }
  let (notHost, _) ← run (edit ben party changes) store
  check "only the host edits" (failsWith notHost .notHost)
  let (_, edited) ← value (← run (edit asha party changes) store)
  let page ← ok (← read (getParty (some asha) party) edited)
  check "edit applied" (page.title.value == "Garden picnic" && page.description.value == "Bring a blanket")
  check "edit kept the date" (page.date == future)
  let hidden ← ok (← read (getParty (some ben) party) edited)
  check "edited visibility applies" (guestNames hidden == none)
  IO.println "PASS proof-carrying access: typed join (each guest once, by id), host-only edits that cannot move the date"

/-- Decision 8 on Memory: cancelling a party deletes its RSVPs, and only its RSVPs. -/
def cascade : IO Unit := do
  let initial : Memory.Store := { now := ← instant 1000 }
  let person := fun (name email : String) (store : Memory.Store) => do
    value (← run (createPerson (← parsed (Name.parse name)) (← parsed (Email.parse email))) store)
  let (ashaId, store) ← person "Asha" "asha@example.com" initial
  let (benId, store) ← person "Ben" "ben@example.com" store
  let (caraId, store) ← person "Cara" "cara@example.com" store
  let asha ← signedIn store ashaId
  let ben ← signedIn store benId
  let cara ← signedIn store caraId
  let future ← instant 5000
  let host := fun (title : String) (store : Memory.Store) => do
    value (← run (hostParty asha (← parsed (Title.parse title)) (← parsed (Text.parse "")) future .everyone) store)
  let (picnic, store) ← host "Picnic" store
  let (dinner, store) ← host "Dinner" store
  let (_, store) ← value (← run (rsvp ben picnic) store)
  let (_, store) ← value (← run (rsvp cara picnic) store)
  let (_, store) ← value (← run (rsvp ben dinner) store)
  check "three RSVPs before" (rows store "Rsvp" == 3)
  let (notHost, unchanged) ← run (cancel ben picnic) store
  check "only the host cancels" (failsWith notHost .notHost && rows unchanged "Rsvp" == 3)
  let (_, after) ← value (← run (cancel asha picnic) store)
  check "the party is gone" (rows after "Party" == 1)
  check "its RSVPs went with it; the other party's stayed" (rows after "Rsvp" == 1)
  check "the cancelled page is notFound" (failsWith (← read (getParty none picnic) after) .notFound)
  let page ← ok (← read (getParty none dinner) after)
  check "the other guest list is intact" (guestNames page == some ["Ben"])
  let (again, _) ← run (cancel asha picnic) after
  check "cancel twice is notFound" (failsWith again .notFound)
  IO.println "PASS cascade: deleting a party deletes exactly its RSVPs (3 → 1), host-only"

def main : IO Unit := do
  plainOperations
  genericBodies
  authentication
  proofCarrying
  cascade

end PostPart1Run

def main := PostPart1Run.main
