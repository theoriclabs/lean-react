import tests.domain.PostPart1
open LeanApp.Domain
def writable : Api := [
  get "/parties/:party/rsvp" rsvp
]
