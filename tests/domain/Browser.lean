/- Compiled browser fixtures (LeanJS) for `browser.test.mjs`: the post's forms and pages over
   LeanAPI's `TestsCore.PostPart1` domain, plus the shared scalar parsers and date editor. -/
import tests.domain.PostViews
import LeanReact.Compiler
import LeanContract.Browser
namespace DomainBrowser
open LeanDb.Model LeanApi.Core Ontology LeanReact.Domain

/-! ## Checked scalars, parsed the same way natively and in the browser -/

def inputs : List (String × String) := [
  ("name", ""), ("name", "  東京😀  "), ("name", String.ofList (List.replicate 120 '😀')),
  ("name", String.ofList (List.replicate 121 '😀')), ("email", " \tALICE@Example.COM\n"),
  ("email", "a@@b"), ("email", "é@a"), ("email", "a b@c"),
  ("password", "  A password 😀  "), ("password", "short"),
  ("instant", "9007199254740993"), ("instant", "9223372036854775807"),
  ("instant", "-9223372036854775808"), ("instant", "9223372036854775808"),
  ("instant", "2026-09-29T12:00"), ("instant", "01")]
private def outcome (parse : Validation String) : String :=
  match parse with | .ok value => "ok:" ++ value | .error errors => "error:" ++ errors.first.code

def parseCase (kind raw : String) : String :=
  match kind with
  | "name" => outcome ((Name.parse raw).map Name.value)
  | "email" => outcome ((Email.parse raw).map Email.value)
  | "password" => outcome ((Password.parse raw).map Password.value)
  | "instant" => outcome ((Instant.parse raw).map (toString ∘ Instant.value))
  | _ => "invalid case"
def results : List String := inputs.map (fun (kind, raw) => parseCase kind raw)

def dateDraft := DateInput.epochDraft
def dateDisplay := DateInput.formatEpoch

/-! ## The post's forms, as form models over typed contracts -/

def guestView := PostViews.guestsView

/-- The host form: `hostParty`'s contract, its one domain error bound to the `date` field. -/
def hostSpec : FormSpec .command hostParty.Input (Ref Party) HostError :=
  { operation := hostParty.operation.contract
    onError := fun | .dateInPast => fieldErrorNamed "date" "Pick a time in the future."
    onSuccess := fun party => go s!"/parties/{party}"
    label := "Host" }

def hostForm (shell : Shell) : LeanReact.Hook (DomainForm hostParty.Input) := useDomainForm hostSpec shell
def hostFormView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  pure (hostSpec.render (← useDomainForm hostSpec shell))
def hostParser := inputParser hostParty.operation.contract.inputCodec
def hostRaw (title description date guestList : String) : Lean.Json :=
  .mkObj [("title", .str title), ("description", .str description), ("date", .str date), ("guestList", .str guestList)]
def parseHost (title description date guestList : String) : String :=
  outcome ((hostParser.parse (hostRaw title description date guestList)).map fun input =>
    input.title.value ++ ":" ++ toString input.date.value)

def signUpSpec : FormSpec .command signUp.Input Session SignUpError :=
  { operation := signUp.operation.contract
    onError := fun | .emailTaken => fieldErrorNamed "email" "This email already has an account."
    onSuccess := fun _ => go "/parties/new"
    establishesSession := signUp.operation.metadata.establishesSession
    label := "Sign up" }
def signUpView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  pure (signUpSpec.render (← useDomainForm signUpSpec shell))

def signInSpec : FormSpec .command signIn.Input Session SignInError :=
  { operation := signIn.operation.contract
    onError := fun | .wrongEmailOrPassword => notice "Wrong email or password."
    onSuccess := fun _ => go "/parties/new"
    establishesSession := signIn.operation.metadata.establishesSession
    label := "Sign in" }
def signInView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  pure (signInSpec.render (← useDomainForm signInSpec shell))

def scalarEditors : List FieldMetadata := HasRecord.fieldMetadata (T := signUp.Input)

/-! ## Typed editors for every scalar kind (a settings form, no domain beyond its input) -/

inductive Audience where
  | everyone
  | members
  | staff
  | hostsOnly

/-- Settings for a mailing: a secret, a mailbox, optional notes and an audience. -/
def configure (secret : Password) (mailbox : Email) (notes : Text) (audience : Audience) : Op Empty Unit :=
  pure ()

derive_operation configure

def settingsSpec : FormSpec .command configure.Input Unit Empty :=
  { operation := configure.operation.contract, onError := nofun, label := "Save" }
def settingsFormView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  pure (settingsSpec.render (← useDomainForm settingsSpec shell))

/-! ## References -/

def partyRef (key : String) : Validation (Ref Party) := Ref.parse key
def personRef (key : String) : Validation (Ref Person) := Ref.parse key

/-! ## Derived views (`render`, `renderWith`) -/

/-- A row type with a reference, a time, a flag, an enum and a text. -/
structure Listing where
  party : Ref Party
  host : Ref Person
  startsAt : Time
  published : Bool
  visibility : GuestListVisibility
  note : Text
  deriving Domain

private def listingJson (party host : Nat) (startsAt : String) (published : Bool) (visibility : String)
    (note : String) : Lean.Json :=
  .mkObj [("party", .num party), ("host", .num host), ("startsAt", .str startsAt), ("published", .bool published),
    ("visibility", .str visibility), ("note", .str note)]

def listings : List Listing :=
  match (Wire.codec (α := List Listing)).decode (.arr #[
      listingJson 7 1 "2026-10-17T19:00:00Z" true "everyone" "Bring snacks",
      listingJson 8 2 "2026-12-31T23:30:05Z" false "hostOnly" ""]) with
  | .ok rows => rows
  | .error _ => []

/-- The derived table of listings. -/
def listingsView : LeanReact.Element := render listings

/-- The same rows with a reference path, a field override and a type override. -/
def listingsCustomView : LeanReact.Element :=
  renderWith {
    refPath := fun type id => if type.name == "Party" then some ("/parties/" ++ id) else none
    fields := [RenderConfig.field "note" fun (note : Text) => LeanReact.DOM.em {} #[LeanReact.text note.value]]
    types := [RenderConfig.type fun (v : GuestListVisibility) =>
      LeanReact.DOM.strong {} #[LeanReact.text (match v with | .everyone => "Public" | .attendees => "Guests" | .hostOnly => "Private")]] }
    listings

/-- One record as a description list, then an absent and a present optional value. -/
def listingView : LeanReact.Element :=
  LeanReact.fragment #[match listings with | row :: _ => render row | [] => LeanReact.empty,
    render (none : Option Nat), render (some (12 : Int))]

/-! ## The mounted app with request-scoped transports -/

def appWithRequests (client : Contract.Interpreter LeanReact.Action)
    (requestClient : LeanReact.ResourceRequest → Contract.Interpreter LeanReact.Action) :
    LeanReact.Component AppProps :=
  PostViews.app.component client (some requestClient)

end DomainBrowser
