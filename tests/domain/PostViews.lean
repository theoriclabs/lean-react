/- The Part 1 post's pages (DDD-LR-06), over the post's domain fixture: `form`, `call` and
   `load` on typed endpoints, `App` with `path ==> page`. Mirrors `partiful_v2/Views.lean`
   for the endpoints LeanAPI's `TestsCore.PostPart1` publishes. -/
import TestsCore.PostPart1
import LeanReact.Domain
import LeanReact.Program
open LeanDb.Model LeanApi.Core LeanReact

namespace PostViews

/-! ## Signing up and in -/

def signUpPage : Element :=
  form api.signUp
    (onSuccess := fun _ => navigate "/")
    (onError := fun
      | .emailTaken => fieldError "email" "This email already has an account. Sign in instead?")

def signInPage : Element :=
  form api.signIn
    (onSuccess := fun _ => navigate "/")
    (onError := fun
      | .wrongEmailOrPassword => notice "Wrong email or password.")

/-! ## Hosting -/

def hostPartyPage : Element :=
  form api.hostParty
    (onSuccess := fun party => navigate s!"/parties/{party}")
    (onError := fun
      | .dateInPast => fieldError "date" "Pick a time in the future.")

/-! ## The party page -/

def guestsView : GuestList → Element
  | .visible guests =>
      DOM.ul {} (guests.map fun g => DOM.li {} #[text g.name]).toArray
  | .hidden =>
      DOM.p {} #[text "The host is keeping the guest list private."]

def partyView (page : PartyPage) (onRsvp : Action Unit) : Element :=
  DOM.div {} #[
    DOM.h1 {} #[text page.title],
    DOM.p {} #[text page.date.format],
    DOM.p {} #[text page.description],
    DOM.button { onPress := some onRsvp } #[text "I'm going"],
    guestsView page.guests
  ]

/-- The "I'm going" button. Saying yes twice is fine: `rsvp` treats it as already going. -/
def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party)
    (onSuccess := fun _ => pure ())
    (onError := fun
      | .notFound       => notice "This party no longer exists."
      | .alreadyStarted => notice "This party has already started.")

def cancelButton (party : Ref Party) : Element :=
  DOM.button {
      onPress := some <| call (api.cancel party)
        (onSuccess := fun _ => navigate "/parties/new")
        (onError := fun
          | .notFound => notice "This party no longer exists."
          | .notHost  => notice "Only the host can cancel this party.") }
    #[text "Cancel party"]

/-- `/parties/:party`. -/
def partyPage (party : Ref Party) : Element :=
  load (api.getParty party)
    (onError := fun
      | .notFound => DOM.p {} #[text "This party doesn't exist."])
    fun page => DOM.div {} #[
      partyView page (rsvpButton party),
      cancelButton party
    ]

/-- `/parties/:party/summary`: the page's data with its derived view, no bespoke view. -/
def partySummaryPage (party : Ref Party) : Element :=
  load (api.getParty party)
    (onError := fun
      | .notFound => DOM.p {} #[text "This party doesn't exist."])
    render

def app : App where
  api   := api
  pages := [
    "/sign-up"        ==> signUpPage,
    "/sign-in"        ==> signInPage,
    "/parties/new"    ==> hostPartyPage,
    "/parties/:party" ==> partyPage,
    "/parties/:party/summary" ==> partySummaryPage
  ]

/-- The compiled entry: the app over a host client. -/
def appComponent (client : Contract.Interpreter Action) : Component LeanReact.Domain.AppProps :=
  app.component client

/-- Host-side constructors for the compiled tests. -/
def appProps (shell : LeanReact.Domain.ShellProps) (location : String) (actor : Option String) :
    LeanReact.Domain.AppProps := { shell, location, actor }
def shellProps (generation : Nat) (currentGeneration : Action Nat)
    (framework : Contract.CallError Empty → Action Unit) (navigate : String → Action Unit)
    (authenticationChanged : Action Unit) : LeanReact.Domain.ShellProps :=
  { generation, currentGeneration, framework, navigate, refresh := pure (), authenticationChanged }

/-! ## A declarative component with typed calls (Components P6) -/

namespace RsvpWidget
open LeanReact.Program

structure Model where
  party : Ref Party
  status : String := ""
  guests : Option Nat := none

inductive Msg where
  | go
  | answered (result : Contract.CallResult Unit RsvpError)
  | loaded (result : Contract.CallResult PartyPage GetPartyError)

private def guestCount : GuestList → Nat
  | .visible guests => guests.length
  | .hidden => 0

/-- Every `RsvpError` the endpoint declares has its own case: removing one is a compile error
(`tests/domain/negative/ProgramRsvpMissingCase.lean`). -/
def update (client : Contract.Interpreter LeanReact.Action) : Msg → Model → Model × Cmd Msg
  | .go, m => ({ m with status := "Sending…" }, Cmd.callBound client (api.rsvp m.party) .answered)
  | .answered (.ok ()), m => ({ m with status := "You're going." }, Cmd.callBound client (api.getParty m.party) .loaded)
  | .answered (.error (.domain .notFound)), m => ({ m with status := "This party no longer exists." }, .none)
  | .answered (.error (.domain .alreadyStarted)), m => ({ m with status := "This party has already started." }, .none)
  | .answered (.error .unauthenticated), m => ({ m with status := "Sign in first." }, .none)
  | .answered (.error _), m => ({ m with status := "Request failed. Try again." }, .none)
  | .loaded (.ok page), m => ({ m with guests := some (guestCount page.guests) }, .none)
  | .loaded (.error (.domain .notFound)), m => ({ m with guests := none }, .none)
  | .loaded (.error _), m => (m, .none)

def view (m : Model) : Html Msg :=
  div [] [
    button [onClick .go] [text "RSVP"],
    p [role "status"] [text m.status],
    when m.guests.isSome (p [dataAttr "testid" "guest-count"] [text s!"{m.guests.getD 0} going"])]

def component (client : Contract.Interpreter LeanReact.Action) : Component (Ref Party) Model Msg where
  init party := ({ party }, .none)
  update _ := update client
  view _ := view

/-- The widget for the party with this key (a bare reference id). -/
def element (client : Contract.Interpreter LeanReact.Action) (key : String) : Element :=
  match (Ref.parse key : Ontology.Validation (Ref Party)) with
  | .ok party => (component client).toElement party
  | .error _ => LeanReact.text "Invalid party."

end RsvpWidget

/-! ## What the surface checks -/

-- Path parameters are page arguments, decoded with the type's wire codec.
#guard (app.pages.map (·.path)) == ["/sign-up", "/sign-in", "/parties/new", "/parties/:party", "/parties/:party/summary"]
#guard ((app.pages[3]?.map fun page => (page.build [("party", "7")]).isSome) == some true)
#guard ((app.pages[3]?.map fun page => (page.build [("party", "seven")]).isSome) == some false)
#guard (LeanReact.Domain.matchRoute "/parties/:party" "/parties/12") == some [("party", "12")]
#guard (LeanReact.Domain.matchRoute "/parties/:party" "/parties/12/rsvp") == none
-- `Time.format` and checked text for display.
#guard (match Instant.ofEpochSeconds 1792263600 with | .ok t => t.format == "2026-10-17 19:00 UTC" | .error _ => false)

end PostViews
