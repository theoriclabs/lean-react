/- The endpoint surface keeps the catch-all rejections: no `_` in `onError`. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party)
    (onError := fun _ => notice "Something went wrong.")
