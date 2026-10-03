/- Optional development integration fixture (needs a LeanDB checkout; not imported by the
   portable package). The post's entities, declared with `deriving Entity` and `constraint`,
   go through LeanDB's existing native schema bridge unchanged, and the published plain
   operations' requirements synthesize against the native family. -/
import tests.domain.PostPart1
import LeanDbDomain.Schema
import LeanDbDomain.Access

native_schema% PostSchema := Person, Party, Rsvp

namespace NativePost
open LeanApp.Domain

@[reducible] def nativeResources : ResourceFamily := LeanDb.Domain.storageResources PostSchema

-- Requirements of plain operations, inferred from the native schema's dictionaries.
def rsvpRequirements : rsvp.Requirements nativeResources := rsvp.Requirements.infer
def createRequirements : createPerson.Requirements nativeResources := createPerson.Requirements.infer
def hostRequirements : hostParty.Requirements nativeResources := hostParty.Requirements.infer
def rsvpAsRequirements : rsvpAs.Requirements nativeResources := rsvpAs.Requirements.infer

-- The single-field constraint reaches the native unique with its declared identity.
#guard (LeanDb.Domain.HasEntityStorage.storage (s := PostSchema) (T := Person)).sourceUnique Person.Unique.uniqueEmail ==
  "Person.uniqueEmail"

-- LeanDB's wave 2 provides the typed lookup capability for declared unique constraints, so
-- the composite `Rsvp.onePerGuest` lookup behind `getParty`/`reschedule` resolves natively.
def pageRequirements : getParty.Requirements nativeResources := getParty.Requirements.infer
def rescheduleRequirements : reschedule.Requirements nativeResources := reschedule.Requirements.infer
end NativePost
