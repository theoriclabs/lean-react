import LeanApp.Domain
open LeanApp.Domain
structure Person where
  name : Name
  email : Email
  deriving Entity
def make (name : Name) (email : Email) : DB (Ref Person) := Person.insert { name, email }
constraint Person.uniqueEmail : unique email
