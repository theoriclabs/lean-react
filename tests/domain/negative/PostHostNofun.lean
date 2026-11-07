/- The host page had nothing to handle before; now it has one thing. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def hostPartyPage : Element :=
  form api.hostParty
    (onSuccess := fun party => navigate s!"/parties/{party}")
    (onError := nofun)
