/- A named catch-all pattern is a wildcard by another name. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party) (onError := fun error => match error with
    | fallback => notice "all failures")
