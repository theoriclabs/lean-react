/- The host page had nothing to handle before; now it has one thing. -/
import tests.domain.PostPart1
import LeanReact.Domain
open LeanApp.Domain LeanReact

def hostPartyPage : Element :=
  form api.hostParty
    (onSuccess := fun party => navigate s!"/parties/{party}")
    (onError := nofun)
