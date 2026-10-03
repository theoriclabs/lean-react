import tests.domain.Operations
import tests.domain.Evolution
import LeanReact.Domain.DateInput
import LeanApp.Domain.Memory
open LeanApp.Domain Ontology PartifulFlows
namespace DomainTests
private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw (IO.userError ("FAIL: " ++ label))
private def ok [Repr E] (value : Except E A) : IO A :=
  match value with | .ok value => pure value | .error error => throw (IO.userError (reprStr error))
private def rejects (label : String) (value : Validation A) : IO Unit :=
  match value with | .ok _ => throw (IO.userError ("accepted " ++ label)) | .error _ => pure ()
private def instant (seconds : Int) : IO Instant := ok (Instant.ofEpochSeconds seconds)
private def actor (store : Memory.Store) (id : Ref Person) : IO (SignedIn Unit Person) := do
  let (row, _) ← ok ((Memory.lookup (Scope := Unit) id).run store)
  match row with | none => throw (IO.userError "missing seeded actor") | some row => pure (Trusted.signedIn row)
private def seedPerson (store : Memory.Store) (name email : String) : IO (Ref Person × Memory.Store) := do
  let value : Person := ⟨← ok (Name.parse name), ← ok (Email.parse email)⟩
  let (result, after) ← ok (Memory.command (Flow.create value : Flow .command Unit rsvp.Error (Ref Person)) store)
  return (← ok result, after)
private def loadParty (store : Memory.Store) (id : Ref Party) : IO (Row Unit Party) := do
  let (row, _) ← ok ((Memory.lookup (Scope := Unit) id).run store)
  match row with | none => throw (IO.userError "party disappeared") | some row => pure row
private def page (store : Memory.Store) (id : Ref Party) (viewer : Viewer Unit Person) : IO (PartyPage × Memory.Store) := do
  let (result, after) ← ok (Memory.read (partyPage.body viewer ⟨id⟩) store)
  return (← ok result, after)
private def hasNames (value : PartyPage) : Bool := match value.guests with | .visible _ => true | .hidden => false
private def hidden (value : PartyPage) : Bool := !hasNames value
private def failIs [BEq E] (result : Except E A) (expected : E) : Bool :=
  match result with | .error error => error == expected | .ok _ => false

private def scalars : IO Unit := do
  check "name trimmed" ((← ok (Name.parse "  東京😀  ")).value == "東京😀")
  rejects "empty name" (Name.parse " \t ")
  let unicode := String.ofList (List.replicate 120 '😀')
  check "120 Unicode scalars" ((← ok (Name.parse unicode)).value == unicode)
  rejects "121 Unicode scalars" (Name.parse (unicode ++ "😀"))
  check "canonical email" ((← ok (Email.parse " \tALICE@Example.COM\n")).value == "alice@example.com")
  for email in ["a", "@x", "x@", "a@@b", "a b@c", "é@a", "a@\u0000b"] do rejects "mailbox" (Email.parse email)
  let raw := "  A password 😀  "
  check "password preservation" ((← ok (Password.parse raw)).value == raw)
  rejects "short password" (Password.parse "short")
  rejects "129 password scalars" (Password.parse (String.ofList (List.replicate 129 'a')))
  check "text empty allowed" ((← ok (Text.parse "")).value == "")
  rejects "long text" (Text.parse (String.ofList (List.replicate 10001 'a')))
  for value in [int64Min, int64Max, 9007199254740993, -9007199254740993] do
    let parsed ← instant value
    let decoded ← ok ((Wire.codec (α := Instant)).decode ((Wire.codec (α := Instant)).encode parsed))
    check "exact epoch wire" (decoded.value == value)
  rejects "epoch high" (Instant.ofEpochSeconds (int64Max + 1))
  rejects "epoch low" (Instant.ofEpochSeconds (int64Min - 1))
  rejects "local datetime requires zone" (Instant.parse "2026-09-29T12:00")
  rejects "noncanonical epoch" (Instant.parse "01")
  let ref ← ok (Ref.parse (T := Party) "9007199254740993")
  check "exact ref wire" ((← ok ((refCodec (T := Party)).decode ((refCodec (T := Party)).encode ref))).key == ref.key)
  for key in ["0", "-1", "01", "9223372036854775808", "1.2"] do rejects "ref key" (Ref.parse (T := Party) key)
  let person ← ok (Ref.parse (T := Person) ref.key)
  rejects "wrong entity tag" ((refCodec (T := Party)).decode ((refCodec (T := Person)).encode person))
  let unknown := (refCodec (T := Party)).encode ref |>.setObjVal! "now" (.str "0")
  rejects "ref unknown key" ((refCodec (T := Party)).decode unknown)
  for malicious in [Lean.Json.mkObj [("tag", .str "hidden"), ("value", .arr #[])],
      Lean.Json.mkObj [("tag", .str "hidden"), ("value", .null), ("count", .num 0)]] do
    rejects "hidden payload" ((disclosureCodec (Wire.codec (α := List Guest))).decode malicious)
  let visibleEmpty := (disclosureCodec (Wire.codec (α := List Guest))).encode (.visible [])
  let hiddenWire := (disclosureCodec (Wire.codec (α := List Guest))).encode .hidden
  check "hidden distinct from authorized empty" (visibleEmpty != hiddenWire)
  check "members omitted from internal row schema" (((Entity.recordRepresentation (T := Party)).schema.toJson.compress.splitOn "guests").length == 1)
  IO.println "PASS scalar canonicalization, exact integers, nominal wire, strict disclosure"

private def flows : IO Unit := do
  let clock ← instant 100
  let initial : Memory.Store := { now := clock }
  let (alice, initial) ← seedPerson initial "Alice" "alice@example.com"
  let (bob, initial) ← seedPerson initial "Bob" "bob@example.com"
  let (carol, initial) ← seedPerson initial "Carol" "carol@example.com"
  let aliceActor ← actor initial alice
  let bobActor ← actor initial bob
  let carolActor ← actor initial carol
  let title ← ok (Title.parse "Party")
  let description ← ok (Text.parse "Hello")
  let future ← instant 200
  let hostInput : host.Input := ⟨title, future, description, .public⟩
  let (hostResult, hosted) ← ok (Memory.command (host.body aliceActor hostInput) initial)
  let id ← ok hostResult
  check "person/party same numeric key stay nominal" (id.key == alice.key)
  let (badHost, _) ← ok (Memory.command (host.body aliceActor { hostInput with date := clock }) initial)
  check "strict future host" (failIs badHost .dateMustBeFuture)
  let (emptyPage, _) ← page hosted id (Trusted.viewer (Scope := Unit) (T := Person) none)
  check "authorized empty" (match emptyPage.guests with | .visible [] => true | _ => false)
  let (first, going) ← ok (Memory.command (rsvp.body bobActor ⟨id⟩) hosted)
  let _ ← ok first
  let (twice, going) ← ok (Memory.command (rsvp.body bobActor ⟨id⟩) going)
  let _ ← ok twice
  check "guests are an idempotent set" (going.members.length == 1)
  let (third, going) ← ok (Memory.command (rsvp.body carolActor ⟨id⟩) going)
  let _ ← ok third
  let (publicPage, _) ← page going id (Trusted.viewer (Scope := Unit) (T := Person) none)
  check "nonempty stable projection" (match publicPage.guests with | .visible guests => guests.map (·.name.value) == ["Bob", "Carol"] | _ => false)
  let bytes := (Wire.codec (α := PartyPage)).encode publicPage |>.compress
  check "guest output contains no emails" ((bytes.splitOn "bob@example.com").length == 1 && (bytes.splitOn "email").length == 1)
  let atStart := { going with now := future }
  let (closed, _) ← ok (Memory.command (rsvp.body bobActor ⟨id⟩) atStart)
  check "exact cutoff even repeat RSVP" (failIs closed .partyStarted)
  let missing ← ok (Ref.parse (T := Party) "999")
  let (missingResult, _) ← ok (Memory.command (reschedule.body bobActor ⟨missing, clock⟩) atStart)
  check "lookup failure precedes host/time" (failIs missingResult .partyMissing)
  let (denied, _) ← ok (Memory.command (reschedule.body bobActor ⟨id, clock⟩) atStart)
  check "host failure precedes time" (failIs denied .hostOnly)
  let (oldDate, _) ← ok (Memory.command (reschedule.body aliceActor ⟨id, ← instant 300⟩) atStart)
  check "old date strictly future" (failIs oldDate .partyStarted)
  let (newDate, _) ← ok (Memory.command (reschedule.body aliceActor ⟨id, clock⟩) going)
  check "new date strictly future" (failIs newDate .dateMustBeFuture)
  let rename ← ok (Title.parse "Renamed")
  let (edited, attendees) ← ok (Memory.command (edit.body aliceActor ⟨id, rename, description, .attendees⟩) going)
  let _ ← ok edited
  let row ← loadParty attendees id
  check "edit preserves host/date/members" (row.value.host == alice && row.value.date == future && attendees.members.length == 2)
  let viewers := [Trusted.viewer (Scope := Unit) (T := Person) none,
    Trusted.viewer (some aliceActor.row), Trusted.viewer (some bobActor.row), Trusted.viewer (some carolActor.row)]
  for (viewer, expected) in viewers.zip [false, false, true, true] do
    let (response, after) ← page attendees id viewer
    check "attendees matrix including host without RSVP" (hasNames response == expected)
    if !expected then check "denial does not project" (after.projectionReads == attendees.projectionReads)
  let (hostRsvp, hostGoing) ← ok (Memory.command (rsvp.body aliceActor ⟨id⟩) attendees)
  let _ ← ok hostRsvp
  check "host gets access only as member" (hasNames (← page hostGoing id (Trusted.viewer (some aliceActor.row))).1)
  let (privacyResult, privateStore) ← ok (Memory.command (edit.body aliceActor ⟨id, rename, description, .private⟩) hostGoing)
  let _ ← ok privacyResult
  for viewer in viewers do
    let (response, after) ← page privateStore id viewer
    check "private hidden including attending host" (hidden response && after.projectionReads == privateStore.projectionReads)
    check "hidden response bytes" ((((Wire.codec (α := PartyPage)).encode response).compress.splitOn "Bob").length == 1)
  let rollback : Flow .command Unit rsvp.Error Unit := do
    let row ← Flow.find id .partyMissing
    Flow.«include» (row.membersField "guests") aliceActor
    Flow.fail .partyStarted
  let (rolled, rollbackStore) ← ok (Memory.command rollback going)
  check "late domain error rollback" (failIs rolled .partyStarted && rollbackStore.members.length == going.members.length)
  let (editedAfter, _) ← ok (Memory.command (edit.body aliceActor ⟨id, rename, description, .private⟩) atStart)
  check "edit permitted after start" editedAfter.isOk
  let (cancelResult, cancelled) ← ok (Memory.command (cancel.body aliceActor ⟨id⟩) atStart)
  let _ ← ok cancelResult
  check "cancel cascades memberships after start" (cancelled.members.isEmpty && cancelled.rows.length == 3)
  check "closed exact errors" (reschedule.metadata.failures == ["partyMissing", "hostOnly", "partyStarted", "dateMustBeFuture"])
  IO.println "PASS six generated flows on nonempty state, visibility matrix, cutoff, precedence, rollback, cascade"

def main : IO Unit := do
  scalars
  flows
  check "UTC epoch" (LeanReact.Domain.DateInput.epochDraft "1970-01-01T00:00" == "0")
  check "UTC before epoch" (LeanReact.Domain.DateInput.formatEpoch (-1) == "1969-12-31T23:59:59")
  check "UTC leap" (LeanReact.Domain.DateInput.epochDraft "2000-02-29T12:34:56" == "951827696")
  check "UTC normalized whole seconds" (LeanReact.Domain.DateInput.epochDraft "2000-02-29T12:34:56.000" == "951827696")
  check "UTC fractional seconds retained" (LeanReact.Domain.DateInput.epochDraft "2000-02-29T12:34:56.001" == "2000-02-29T12:34:56.001")
  check "UTC invalid leap retained" (LeanReact.Domain.DateInput.epochDraft "1900-02-29T00:00" == "1900-02-29T00:00")
  check "UTC range roundtrip" (LeanReact.Domain.DateInput.epochDraft (LeanReact.Domain.DateInput.formatEpoch 253402300799) == "253402300799")
  IO.println "PASS UTC calendar editor/display boundary cases"
  let store : Memory.Store := { now := ← instant 0 }
  let (composed, _) ← ok (Memory.command (Composition.callerEvolved.body () ⟨true, false⟩ : Flow .command Unit _ _) store)
  check "callee closed failure propagation" (failIs composed .calleeEvolved_notReady)
  let name ← ok (Name.parse "Alice")
  let firstEmail ← ok (Email.parse "alice@example.test")
  let secondEmail ← ok (Email.parse "bob@example.test")
  let (first, store) ← ok (Memory.command (Flow.create (ChangeUnique.Person.mk name firstEmail) : Flow .command Unit ChangeUnique.rename.Error _) store)
  let first ← ok first
  let (second, store) ← ok (Memory.command (Flow.create (ChangeUnique.Person.mk name secondEmail) : Flow .command Unit ChangeUnique.rename.Error _) store)
  let _ ← ok second
  let (collision, unchanged) ← ok (Memory.command (ChangeUnique.rename.body () ⟨first, secondEmail⟩ : Flow .command Unit _ _) store)
  check "changed-field unique closed failure" (failIs collision .emailTaken)
  check "failed changed uniqueness rolls back" (unchanged.rows == store.rows)
  IO.println "PASS callee error composition and changed-field uniqueness on populated state"
end DomainTests

def main := DomainTests.main
