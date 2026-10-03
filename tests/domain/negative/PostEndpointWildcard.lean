/- The endpoint surface keeps the catch-all rejections: no `_` in `onError`. -/
import tests.domain.PostPart1
import LeanReact.Domain
open LeanApp.Domain LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party)
    (onError := fun _ => notice "Something went wrong.")
