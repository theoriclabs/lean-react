/- `fieldError` names a field of the endpoint's input record. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def hostPartyPage : Element :=
  form api.hostParty
    (onSuccess := fun _ => navigate "/")
    (onError := fun | .dateInPast => fieldError "bogus" "Pick a time in the future.")
