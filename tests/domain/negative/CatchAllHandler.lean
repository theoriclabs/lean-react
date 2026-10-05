/- A handler that ignores which error happened is not an explicit branch per case. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party) (onError := fun error => notice "oops")
