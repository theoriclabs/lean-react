import tests.domain.PartifulViews
import tests.domain.Evolution
import LeanReact.Compiler
import LeanContract.Browser
namespace DomainBrowser
open LeanApp.Domain LeanReact.Domain Ontology

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

def guestView := Partiful.guestsView

def hostParser := inputParser Partiful.host.contract.inputCodec

def hostForm (shell : Shell) : LeanReact.Hook (DomainForm Partiful.host.Input) := useDomainForm Partiful.hostPage shell

def partyComponent (client : Contract.Interpreter LeanReact.Action) :=
  Partiful.partyScreen.component (A := Partiful.Person) client

def partyComponentWithRequests (client : Contract.Interpreter LeanReact.Action)
    (requestClient : LeanReact.ResourceRequest → Contract.Interpreter LeanReact.Action) :=
  Partiful.partyScreen.component (A := Partiful.Person) client (some requestClient)

def hostRaw (title description date visibility : String) : Lean.Json :=
  .mkObj [("title", .str title), ("description", .str description), ("date", .str date), ("visibility", .str visibility)]
def parseHost (title description date visibility : String) : String :=
  outcome (((inputParser Partiful.host.contract.inputCodec).parse (hostRaw title description date visibility)).map fun input => input.title.value ++ ":" ++ toString input.date.value)
def hostFormView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  let model ← useDomainForm Partiful.hostPage shell
  pure (Partiful.hostPage.render model)
def signUpView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  let model ← useDomainForm Partiful.signUpPage shell
  pure (Partiful.signUpPage.render model)
def scalarEditors : List FieldMetadata := HasRecord.fieldMetadata (T := Partiful.account.signUp.Input)
def partyRef (key : String) : Validation (Ref Partiful.Party) := Ref.parse key

def personRef (key : String) : Validation (Ref Partiful.Person) := Ref.parse key

def pageOutput (visible : Bool) (guest : String) : Validation Partiful.PartyPage := do
  let title ← Title.parse "Fixture party"
  let date ← Instant.ofEpochSeconds 200
  let description ← Text.parse ""
  let guests ← if visible then (Name.parse guest).map (fun name => Disclosure.visible [Partiful.Guest.mk name]) else pure Disclosure.hidden
  pure { title, date, description, visibility := if visible then .public else .private, guests }

def renamedFormView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  let model ← useDomainForm EditorFixtures.renamedPage shell
  pure (EditorFixtures.renamedPage.render model)
def signInView (shell : Shell) : LeanReact.Hook LeanReact.Element := do
  let model ← useDomainForm Partiful.signInPage shell
  pure (Partiful.signInPage.render model)
def dateDraft := DateInput.epochDraft
def dateDisplay := DateInput.formatEpoch
end DomainBrowser
