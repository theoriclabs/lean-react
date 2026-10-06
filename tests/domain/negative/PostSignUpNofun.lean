/- After `constraint Person.uniqueEmail`, `signUp` has `SignUpError.emailTaken`, and last
   week's page (`SignUpEvolution`) stops compiling with the post's exact message. -/
import TestsCore.PostPart1
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

def signUpPage : Element :=
  form api.signUp
    (onSuccess := fun _ => navigate "/")
    (onError := nofun)   -- signUp can't fail
