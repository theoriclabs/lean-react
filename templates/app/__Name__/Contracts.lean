import {{Name}}.Domain
import LeanContract
import LeanContract.Http

namespace {{Name}}
open Ontology Contract

/-- Wire namespace of this application's operations. Renaming it is a protocol change. -/
def packageId := "{{namespace}}"

structure Note where
  id : String
  title : String
  deriving Repr, BEq

instance : Wire Note where
  codec := {
    schema := .record [("id", .string), ("title", .string)]
    encode note := .mkObj [("id", .str note.id), ("title", .str note.title)]
    decode value := do
      JsonWire.object ["id", "title"] value
      pure ⟨← Codec.field "id" Codec.string value, ← Codec.field "title" Codec.string value⟩ }

/-- The `add` input is a `Title`, so the server re-runs the domain rule on every request; a
hand-written client cannot skip it. -/
instance : Wire Title where
  codec := {
    schema := .string
    encode title := .str title.value
    decode value := do
      match Title.parse (← Codec.string.decode value) with
      | .ok title => pure title
      | .error code => Validation.fail code }

def listIdentity : OperationId := ⟨packageId, "list", "1"⟩
def addIdentity : OperationId := ⟨packageId, "add", "1"⟩
def listPath := "/api/notes/list"
def addPath := "/api/notes/add"

/-- The service the LeanReact screen consumes. The browser host builds it over the generated wire
client; a test can pass an in-memory one. -/
structure NoteService (m : Type → Type) where
  list : m (Except String (Array Note))
  add : Title → m (Except String Note)

end {{Name}}
