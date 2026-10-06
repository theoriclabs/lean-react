/- The RSVP button must handle `alreadyStarted` (DDD-LR-06). -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party)
    (onError := fun
      | .notFound => notice "This party no longer exists.")
