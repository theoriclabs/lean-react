/- Changing `PartyPage.guests` to `GuestList` breaks a view written for `List Guest`. -/
import tests.domain.PostPart1
import LeanReact.Domain
open LeanApp.Domain LeanReact

def guestsView (guests : List Guest) : Element :=
  DOM.ul {} (guests.map fun g => DOM.li {} #[text g.name]).toArray

def partyView (page : PartyPage) (onRsvp : Action Unit) : Element :=
  DOM.div {} #[
    DOM.h1 {} #[text page.title],
    DOM.button { onPress := some onRsvp } #[text "I'm going"],
    guestsView page.guests
  ]
