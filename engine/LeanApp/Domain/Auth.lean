import LeanApp.Domain.Op

/-! # Authentication as ordinary operations (portable half of DDD-LAPI-06)

```
structure Login where
  member : Ref Member
  secret : PasswordHash
  deriving Entity
credential Login.member Login.secret        -- generates Login.verify

def register (name : Name) (email : Email) (password : Password) : Op RegisterError Session := do
  match ← Member.insert { name, email } with
  | .error .uniqueEmail => throw .alreadyRegistered
  | .ok id =>
    let _ ← Login.insert { member := id, secret := ← password.hash }
    Auth.startSession id

def logIn (email : Email) (password : Password) : Op LogInError Session := do
  let some id ← Login.verify (← Member.findBy email) password
    | throw .badCredentials
  Auth.startSession id
```

The credential entity is app code, declared explicitly with `credential C.profileField C.hashField`. The KDF steps are IR requests, so the
runtime can hoist them before writer admission (decision 4): publication records, in
`FlowMetadata.kdf`, the input field each one consumes, and rejects an operation whose KDF
input is not one of its own arguments. -/

namespace LeanApp.Domain

/-- Hash a password with the runtime's KDF. Prepared before writer admission. -/
def Password.hash {ε : Type} (password : Password) : Op ε PasswordHash :=
  Flow.request (.hashPassword password)

namespace Auth

/-- Generic credential check behind each generated `C.verify`. For `none` it still does the
KDF work (decision 2), so an unknown email and a wrong password cost the same. -/
def verifyWith [Entity C] [credentials : HasEntityResource portableResources C] [Entity T] [HasRow T R]
    (link : CredentialLink C T) (profile : Option (R OpScope)) (password : Password) : Op ε (Option (Ref T)) :=
  Flow.request (.verifyCredential credentials.witness link (profile.map (HasRow.toRow (T := T))) password)

/-- Start a session for `profile`, atomically with the operation's writes. The runtime sets the
cookie (or adds the token to a token-mode reply) only after commit. -/
def startSession [Entity T] [storage : HasEntityResource portableResources T]
    [HasAuthResource portableResources T storage.witness] (profile : Ref T) : Op ε Session :=
  Flow.request (.startSession storage.witness HasAuthResource.witness profile)

end Auth
end LeanApp.Domain
