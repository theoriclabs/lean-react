import LeanAppNative
import LeanAppNative.Auth.Http
import {{Name}}.Contracts

namespace {{Name}}Native
open LeanApp LeanDb {{Name}}

/-- One row per note. `actor`/`tenant` scope every read and write to the signed-in principal. -/
structure NoteRow where
  publicId : String
  actor : String
  tenant : String
  title : String
  deriving LeanDb.Entity

/-- The auth tables plus this application's rows; schema drift is refused at open. -/
def base : Base := { name := "{{name}}", tables := LeanAppNative.Auth.tables ++ [.of NoteRow] }

private def db (conn : Conn) (action : DbM α) : IO α := do
  let .ok result ← DbM.run conn action | throw (IO.userError "{{name}} storage unavailable")
  pure result

/-- Owner and tenant both match: a guessed id from another account is indistinguishable from a
missing one. -/
private def rows (p : Principal) : DbM (Array (Stored NoteRow)) :=
  selectP [NoteRow] (.and (.eq (.here NoteRow.Field.actor) .eq p.actor)
    (.eq (.here NoteRow.Field.tenant) .eq p.tenant))

def listNotes (conn : Conn) (p : Principal) : IO (Array Note) := db conn do
  return (← rows p).map fun row => ⟨row.val.publicId, row.val.title⟩

/-- The limit is checked inside the same write transaction as the insert. -/
def addNote (conn : Conn) (p : Principal) (title : Title) : IO (Except String Note) := do
  let id ← LeanAppNative.Auth.Crypto.randomToken
  db conn <| transaction do
    if (← rows p).size ≥ 100 then return .abort "notes.limit"
    discard <| insert NoteRow ⟨id, p.actor, p.tenant, title.value⟩
    return .commit ⟨id, title.value⟩

end {{Name}}Native
