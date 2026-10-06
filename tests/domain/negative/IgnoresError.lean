/- Matching on something other than the error argument handles no case. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party) (onError := fun error => match true with
    | .true => notice "all failures"
    | .false => notice "all failures")
