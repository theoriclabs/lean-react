import tests.domain.Partiful
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain Ontology
namespace Partiful
command% fuller (me : SignedIn Person) (id : Ref Party) (available : Bool) : Unit := do
  let party ← find Party id else partyMissing
  require now < party.date else partyStarted
  require available else partyFull
  include me.id in party.guests
-- This fixture tests closed-error evolution with a real supplied Boolean guard;
-- it is not an authored Partiful capacity feature or native capacity policy.
def repaired := form fuller onError fun
  | .partyMissing => notice "missing"
  | .partyStarted => notice "started"
  | .partyFull => notice "full"
end Partiful
namespace NoUnique
@[entity] structure Person where
  name : Name
  email : Email
auth% account : Person using emailPassword(email)
def emptyHandler : account.signUp.Error → String := fun error => nomatch error
def noFailures := form account.signUp onError fun error => nomatch error
end NoUnique
namespace WithUnique
@[entity] structure Person where
  name : Name
  email : Email
unique% Person.byEmail := email
auth% account : Person using emailPassword(email)
def closedHandler : account.signUp.Error → String
  | .emailTaken => "taken"
command% relaySignUp (name : Name) (email : Email) (password : Password) : Ref Person := do
  call account.signUp () ⟨name, email, password⟩
#check relaySignUp.Error.signUp_emailTaken
#guard relaySignUp.metadata.establishesSession
#guard (relaySignUp.metadata.nodes.find? (fun node => node.kind == "call")).map (·.effect) == some .command
end WithUnique
namespace EditorFixtures
inductive Visibility where
  | «public» | attendees | «private» | hostsOnly
  deriving Domain
structure Renamed where
  secret : Password
  mailbox : Email
  notes : Text
  visibility : Visibility := .hostsOnly
  deriving Domain
#guard (HasRecord.fieldMetadata (T := Renamed)).map (fun field => (field.name, field.editor.kind, field.editor.required)) ==
  [("secret", .password, true), ("mailbox", .email, true), ("notes", .text, false), ("visibility", .choices, true)]
#guard (HasRecord.defaultValues (T := Renamed)).map Prod.fst == ["visibility"]
end EditorFixtures
namespace EditorFixtures
command% checkRenamed (secret : Password) (mailbox : Email) (notes : Text)
    (visibility : Visibility := .hostsOnly) : Unit := do
  require mailbox.value != "taken@example.test" else mailboxTaken
  pure ()
def renamedPage := form checkRenamed onError fun
  | .mailboxTaken => fieldError .mailbox "Taken."
end EditorFixtures

namespace Composition
command% callee (allowed : Bool) : Unit := do
  require allowed else denied
  pure ()
command% caller (allowed : Bool) : Unit := do
  call callee () ⟨allowed⟩
#guard caller.metadata.failures == ["callee_denied"]
def handled : caller.Error → String
  | .callee_denied => "denied"
command% calleeEvolved (allowed : Bool) (ready : Bool) : Unit := do
  require allowed else denied
  require ready else notReady
  pure ()
command% callerEvolved (allowed : Bool) (ready : Bool) : Unit := do
  call calleeEvolved () ⟨allowed, ready⟩
#guard callerEvolved.metadata.failures == ["calleeEvolved_denied", "calleeEvolved_notReady"]
end Composition
namespace ChangeUnique
@[entity] structure Person where
  name : Name
  email : Email
unique% Person.byEmail := email
command% rename (id : Ref Person) (email : Email) : Unit := do
  let person ← find Person id else missing
  change person { email }
#guard rename.metadata.failures == ["missing", "emailTaken"]
#guard (rename.metadata.nodes.find? (fun node => node.kind == "change")).map (·.constraints) == some ["ChangeUnique.Person.byEmail"]
end ChangeUnique

namespace GuardEvidence
command% futureProof (date : Instant) : Unit := do
  require date > now else future as established
  let usable : now < date := established.down
  pure ()
#domain_inspect futureProof
end GuardEvidence
