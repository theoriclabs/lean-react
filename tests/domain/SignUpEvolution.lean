/- The post's sign-up story, before the email constraint (DDD-LR-06 acceptance). `signUp` and
   `hostParty` cannot fail yet, so their pages say so with `(onError := nofun)`. The negative
   fixtures `PostSignUpNofun` and `PostHostNofun` are the same pages against the final domain
   (LeanAPI's `TestsCore.PostPart1`), where Lean reports the exact missing cases. -/
import LeanDb.Model
import LeanApi.Core
import LeanReact.Domain
open LeanDb.Model LeanApi.Core LeanReact

namespace SignUpBefore

structure Person where
  name  : Name
  email : Email
  deriving Entity

structure Party where
  host  : Ref Person
  title : Title
  date  : Time
  deriving Entity

structure SignedIn where
  private mk ::
  id : Ref Person
  deriving Principal

structure Credential where
  person : Ref Person
  hash   : PasswordHash
  deriving Entity

credential Credential.person Credential.hash

-- No `constraint Person.uniqueEmail` yet: `Person.insert` cannot fail, so neither can `signUp`.
def signUp (name : Name) (email : Email) (password : Password) : Op Empty Session := do
  let id ← Person.insert { name, email }
  let _ ← Credential.insert { person := id, hash := ← password.hash }
  Auth.startSession id

-- No date rule yet.
def hostParty (me : SignedIn) (title : Title) (date : Time) : Op Empty (Ref Party) :=
  Party.insert { host := me.id, title, date }

def api : Api := [
  post "/sign-up" signUp,
  post "/parties" hostParty
]

def signUpPage : Element :=
  form api.signUp
    (onSuccess := fun _ => navigate "/")
    (onError := nofun)   -- signUp can't fail

def hostPartyPage : Element :=
  form api.hostParty
    (onSuccess := fun party => navigate s!"/parties/{party}")
    (onError := nofun)

/-- info: SignUpBefore.api.signUp : Endpoint signUp.Input Empty Session -/
#guard_msgs in #check api.signUp

end SignUpBefore
