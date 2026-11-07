/- A wildcard in `onError` would keep compiling through every new error case. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party) (onError := fun | _ => notice "oops")
