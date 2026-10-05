import tests.domain.Operations
import LeanReact.Domain
open LeanApp.Domain LeanReact.Domain
namespace PartifulFlows

def hostPage := form host
  onError fun
    | .dateMustBeFuture => fieldError .date "Choose a future date."
  onSuccess fun party => go ("/parties/" ++ party.key)

def guestsView : Disclosure (List Guest) → LeanReact.Element
  | .visible guests => list guests fun guest => text guest.name
  | .hidden => text "The guest list is private."

def partyView (party : PartyPage) := page do
  heading party.title
  dateTime party.date
  paragraph party.description
  render (guestsView party.guests)

def partyScreen := screen partyPage partyView
  onError fun
    | .partyMissing => notice "This party no longer exists."
  withActions [
    button "I'm going" rsvp onError fun
      | .partyMissing => notice "This party no longer exists."
      | .partyStarted => notice "RSVPs have closed.",
    form edit onError fun
      | .partyMissing => notice "This party no longer exists."
      | .hostOnly => notice "Only the host can edit this party.",
    form reschedule onError fun
      | .partyMissing => notice "This party no longer exists."
      | .hostOnly => notice "Only the host can change the date."
      | .partyStarted => notice "A party that has started cannot be rescheduled."
      | .dateMustBeFuture => fieldError .date "Choose a future date.",
    button "Cancel party" cancel onError fun
      | .partyMissing => notice "This party no longer exists."
      | .hostOnly => notice "Only the host can cancel this party."
    onSuccess fun _ => go "/parties/new"
  ]
end PartifulFlows
