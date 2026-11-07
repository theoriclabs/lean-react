/- `onError` is always required, even when the endpoint's error type is `Empty`. -/
import tests.domain.SignUpEvolution
open LeanDb.Model LeanApi.Core LeanReact

def signUpPage : Element :=
  form SignUpBefore.api.signUp
    (onSuccess := fun _ => navigate "/")
