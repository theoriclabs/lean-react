import LeanAppNative.Auth.Http
import PrivateNotes

namespace LeanAppNative.Notes
open LeanApp LeanDb Contract Ontology
abbrev Subject := _root_.PrivateNotes.Principal
abbrev Facts := _root_.PrivateNotes.SessionFacts
abbrev Criteria := _root_.PrivateNotes.Criteria
abbrev Answer := _root_.PrivateNotes.Response

structure NoteRow where
  fixtureActor : String
  owner : String
  tenant : String
  title : String
  body : String
  deriving LeanDb.Entity

def base : Base := { name := "leanapp_private_notes", tables := Auth.tables ++ [.of NoteRow] }

private def decimal (value : Lean.Json) (max : Nat := 9223372036854775807) : Validation Nat := do
  let text ← Codec.string.decode value
  let some n := text.toNat? | Validation.fail "notes.invalid_integer"
  if text != toString n || n > max then Validation.fail "notes.invalid_integer"
  pure n

instance : Wire Criteria where
  codec := {
    schema := .record [("search", .string), ("id", .option .string), ("offset", .string), ("limit", .string)]
    encode c := .mkObj [("search", .str c.search), ("id", c.id.map (fun n => .str (toString n)) |>.getD .null),
      ("offset", .str (toString c.offset)), ("limit", .str (toString c.limit))]
    decode value := do
      JsonWire.object ["search", "id", "offset", "limit"] value
      let search ← Codec.field "search" Codec.string value
      if search.length > 100 || search.contains "\x00" then Validation.fail "notes.invalid_search"
      let idValue ← JsonWire.get "id" value
      let id ← if idValue == .null then pure none else some <$> decimal idValue
      let offset ← decimal (← JsonWire.get "offset" value) 10000
      let limit ← decimal (← JsonWire.get "limit" value) 100
      pure ⟨search, id, offset, limit⟩ }

private def viewCodec : Codec _root_.PrivateNotes.NoteView where
  schema := .record [("id", .string), ("title", .string), ("body", .string)]
  encode n := .mkObj [("id", .str (toString n.id)), ("title", .str n.title), ("body", .str n.body)]
  decode v := do
    JsonWire.object ["id", "title", "body"] v
    pure ⟨← decimal (← JsonWire.get "id" v), ← Codec.field "title" Codec.string v,
      ← Codec.field "body" Codec.string v⟩

instance : Wire Answer where
  codec := {
    schema := .record [("notes", .array viewCodec.schema), ("count", .string),
      ("notFound", .boolean), ("tooMany", .boolean)]
    encode r := .mkObj [("notes", (Codec.list viewCodec).encode r.notes), ("count", .str (toString r.count)),
      ("notFound", .bool r.notFound), ("tooMany", .bool r.tooMany)]
    decode v := do
      JsonWire.object ["notes", "count", "notFound", "tooMany"] v
      pure ⟨← Codec.field "notes" (Codec.list viewCodec) v, ← decimal (← JsonWire.get "count" v),
        ← Codec.field "notFound" Codec.bool v, ← Codec.field "tooMany" Codec.bool v⟩ }

structure LabInfo where
  foreignId : String
  archiveId : String

instance : Wire LabInfo where
  codec := {
    schema := .record [("foreignId", .string), ("archiveId", .string)]
    encode v := .mkObj [("foreignId", .str v.foreignId), ("archiveId", .str v.archiveId)]
    decode v := do
      JsonWire.object ["foreignId", "archiveId"] v
      pure ⟨← Codec.field "foreignId" Codec.string v, ← Codec.field "archiveId" Codec.string v⟩ }

private def db (conn : Conn) (action : DbM α) : IO α := do
  let .ok value ← DbM.run conn action | throw (IO.userError "notes storage unavailable")
  pure value

private def ensureLive (alive : IO.Ref Bool) : IO Unit := do
  unless ← alive.get do throw (IO.userError "protected request lease ended")

/-- Trusted fixture provisioning, distinct from the five proved read operations.
Only synthetic data is accepted. A caller cannot name another actor or supply note text. -/
private def setup (conn : Conn) (alive : IO.Ref Bool) (p : Subject) : IO LabInfo := do
  ensureLive alive
  db conn do
    let old ← selectP [NoteRow] (.eq (.here NoteRow.Field.fixtureActor) .eq p.actor)
    let rows ← if old.isEmpty then do
      let mut made := #[]
      for (owner, tenant, title, body) in [
        (p.actor, p.tenant, "Launch budget", "Your launch budget: a small, carefully scoped beginning."),
        (p.actor, p.tenant, "Garden notes", "Plant the rosemary by the kitchen window."),
        ("other:" ++ p.actor, p.tenant, "Launch budget", "FOREIGN-OWNER-CANARY"),
        (p.actor, "archive:" ++ p.tenant, "Launch budget", "FOREIGN-TENANT-CANARY")] do
        made := made.push (← insert NoteRow ⟨p.actor, owner, tenant, title, body⟩)
      pure made
    else pure old
    let some foreign := rows.find? (fun r => r.val.owner != p.actor)
      | throw (.sqlite "incomplete synthetic fixture")
    let some archive := rows.find? (fun r => r.val.owner == p.actor && r.val.tenant != p.tenant)
      | throw (.sqlite "incomplete synthetic fixture")
    pure ⟨toString foreign.id.toInt64.toInt, toString archive.id.toInt64.toInt⟩

private def decodeRow (row : Stored NoteRow) : Except String _root_.PrivateNotes.Note := do
  let id := row.id.toInt64.toInt
  if id ≤ 0 || row.val.title.length > 200 || row.val.body.length > 8192 ||
      row.val.title.contains "\x00" || row.val.body.contains "\x00" then throw "notes.invalid_storage"
  pure ⟨id.toNat, row.val.owner, row.val.tenant, row.val.title, row.val.body⟩

/-- Proof-carrying DB entry point: caller/facts/request brand match the required grant.
The query renderer, connection and decoded row provenance remain trusted native code. -/
def protectedRead (conn : Conn) (alive : IO.Ref Bool)
    (grant : _root_.PrivateNotes.ReadGrant τ s p) (op : _root_.PrivateNotes.Operation)
    (input : Criteria) : IO (Except String Answer) := do
  ensureLive alive
  let stored ← db conn <| selectP [NoteRow] (.and
    (.eq (.here NoteRow.Field.owner) .eq p.actor) (.eq (.here NoteRow.Field.tenant) .eq p.tenant))
  -- The public example can create only two owned rows per account. Bound malformed storage.
  if stored.size > 100 then throw (IO.userError "notes bounded fixture exceeded")
  let .ok rows := stored.toList.mapM decodeRow | throw (IO.userError "invalid stored note")
  let .ok checked := _root_.PrivateNotes.certify grant rows
    | throw (IO.userError "protected row scope mismatch")
  let response := _root_.PrivateNotes.respond (_root_.PrivateNotes.visible p checked.rows) op input
  if response.notFound then return .error "notes.not_found"
  if response.tooMany then return .error "notes.export_limit"
  pure (.ok response)

inductive Read (τ : Type) (s : Facts) (p : Subject) : Type → Type where
  | query (grant : _root_.PrivateNotes.ReadGrant τ s p)
      (op : _root_.PrivateNotes.Operation) (input : Criteria) : Read τ s p (Except String Answer)

inductive Write : Type → Type where
  | lab : Write LabInfo

private def assemble (user : Auth.User) (now expiresAt : Nat)
    (storage : Option (Conn × IO.Ref Bool)) : Validation (Application IO) := do
  let p : Subject := ⟨user.actor, user.tenant, user.generation⟩
  -- resolveSession checked these facts in the same native transaction. No browser fields issue them.
  let s : Facts := ⟨p.actor, p.tenant, p.generation, p.generation, true, expiresAt, now⟩
  let .ok grant := _root_.PrivateNotes.authorize Unit s p | Validation.fail "notes.invalid_authority"
  let readCap : ReadCapability IO (Read Unit s p) := {
    read := fun | .query evidence op input => do
      let some (conn, alive) := storage | throw (IO.userError "inert notes template")
      protectedRead conn alive evidence op input }
  let writeCap : CommandCapability IO (Read Unit s p) Write := {
    toRead := readCap
    write := fun .lab => do
      let some (conn, alive) := storage | throw (IO.userError "inert notes template")
      setup conn alive p }
  let policy := fun (ctx : RequestContext) =>
    ctx.principal == some (LeanApp.Principal.mk p.actor p.tenant p.generation)
  let mut exports := []
  for (name, action) in [("list", _root_.PrivateNotes.Operation.list), ("lookup", .lookup),
      ("search", .search), ("count", .count), ("export", .export)] do
    let op : Contract.Operation .query Criteria Answer String ← Contract.Operation.canonical .query ⟨"notes", name, "1"⟩
    let binding : Binding IO (Read Unit s p) Write op := {
      http := { path := "/api/notes/" ++ name }
      policy := fun ctx _ _ => pure <| if policy ctx then .ok () else .error .unauthenticated
      handler := fun _ cap input => do
        if action == .lookup && input.id.isNone then return .error "notes.not_found"
        cap.read (.query grant action input) }
    exports := exports ++ [binding.approve (fun _ => readCap)]
  let labOp : Contract.Operation .command Unit LabInfo String ← Contract.Operation.canonical .command ⟨"notes", "lab", "1"⟩
  let lab : Binding IO (Read Unit s p) Write labOp := {
    http := { path := "/api/notes/lab" }
    policy := fun ctx _ _ => pure <| if policy ctx then .ok () else .error .unauthenticated
    handler := fun _ cap _ => return .ok (← cap.write .lab) }
  Application.create "private-notes" [{ name := "notes", exports := exports ++ [lab.approve (fun _ => writeCap)] }]

def host (auth : Auth.Service) (origin : String) (development : Bool := false)
    (maxConnections : Nat := 64) : IO Auth.Host := do
  let .ok template := assemble ⟨"template", "template", "template", 0⟩ 0 1 none
    | throw (IO.userError "invalid notes template")
  let .ok codecs := Http.codecs | throw (IO.userError "invalid HTTP codecs")
  let mut statuses := []
  for name in ["list", "lookup", "search", "count", "export"] do
    let .ok op := (Contract.Operation.canonical .query ⟨"notes", name, "1"⟩ : Validation (Contract.Operation .query Criteria Answer String))
      | throw (IO.userError "invalid notes operation")
    statuses := statuses ++ [Http.ErrorStatus.ofOperation op (fun e => if e == "notes.not_found" then 404 else 422)]
  let .ok server := Server.create template codecs { maxBodyBytes := 4096, errorStatuses := statuses, maxConnections }
    | throw (IO.userError "invalid notes server")
  let .ok host := Auth.Host.createSnapshot auth server
      (fun conn user now expiresAt alive => assemble user now expiresAt (some (conn, alive))) origin development
    | throw (IO.userError "invalid notes host")
  pure host

end LeanAppNative.Notes
