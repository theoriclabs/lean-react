import tests.domain.PostPart1
open LeanApp.Domain
def misnamed : Api := [
  post "/parties/:partyId/rsvp" rsvp
]
