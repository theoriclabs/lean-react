/- The RSVP button must handle `alreadyStarted` (DDD-LR-06). -/
import tests.domain.PostPart1
import LeanReact.Domain
open LeanApp.Domain LeanReact

def rsvpButton (party : Ref Party) : Action Unit :=
  call (api.rsvp party)
    (onError := fun
      | .notFound => notice "This party no longer exists.")
