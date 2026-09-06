import Examples.Tickets.Contracts
import LeanDb.Db
import LeanDb.Derive
import Std.Sync.Mutex

namespace NativeTickets
open Ontology Examples.Tickets Examples.Tickets.Contracts

/-- SQLite's `Stored TicketRow.id` is internal. Public identity has separate columns.
    Revisions use TEXT because LeanDB integer columns are bounded Int64 values. -/
structure TicketRow where
  publicScope : String
  publicKey : String
  revisionText : String
  titleText : String
  statusText : String
  assigneeScope : Option String
  assigneeKey : Option String
  deriving Repr, LeanDb.Entity

def TicketRow.ofSummary (ticket : TicketSummary) : TicketRow := {
  publicScope := ticket.id.scope.value
  publicKey := ticket.id.key
  revisionText := toString ticket.revision
  titleText := ticket.value.title.value
  statusText := statusName ticket.value.status
  assigneeScope := ticket.value.assignee.map (·.scope.value)
  assigneeKey := ticket.value.assignee.map (·.key) }

def TicketRow.toSummary (row : TicketRow) : Validation TicketSummary := do
  let id ← EntityId.parse row.publicScope row.publicKey
  let revision ← Codec.nat.decode (JsonWire.tagged "nat" (.str row.revisionText))
  let title ← titleCodec.decode (.str row.titleText)
  let status ← statusCodec.decode (.str row.statusText)
  let assignee ← match row.assigneeScope, row.assigneeKey with
    | none, none => pure none
    | some scope, some key => some <$> EntityId.parse scope key
    | _, _ => Validation.fail "storage.partial_assignee"
  pure ⟨id, revision, ⟨title, status, assignee⟩⟩

private def storedSummary (stored : LeanDb.Stored TicketRow) : LeanDb.DbM TicketSummary :=
  LeanDb.DbM.ofExcept (stored.val.toSummary.mapError fun errors =>
    .decode (LeanDb.Entity.tableName TicketRow) "public_value" (reprStr errors))

private def findRow (id : TicketId) : LeanDb.DbM (Option (LeanDb.Stored TicketRow)) := do
  let rows ← LeanDb.fetchAll TicketRow
  pure (rows.find? fun row => row.val.publicScope == id.scope.value && row.val.publicKey == id.key)

private def saveCurrent (input : SaveTicket) : LeanDb.DbM (Except SaveError TicketSummary) := do
  let some old ← findRow input.id | return .error .notFound
  let current ← storedSummary old
  match applySave current input with
  | .error error => return .error error
  | .ok updated =>
    try
      let saved ← LeanDb.update old (TicketRow.ofSummary updated)
      return .ok (← storedSummary saved)
    catch error =>
      match error with
      | .notFound .. => return .error .notFound
      | .stale .. =>
        let some latest ← LeanDb.get old.id | return .error .notFound
        return .error (.conflict (← storedSummary latest))
      | other => throw other

/-- The sibling transaction helper is private. Flat records avoid nested child transactions.
    BEGIN IMMEDIATE also serializes writers using other SQLite connections/processes. -/
private def transaction (conn : LeanDb.Conn) (action : LeanDb.DbM α) : IO (Except LeanDb.DbError α) := do
  try conn.raw.exec "BEGIN IMMEDIATE"
  catch error => return .error (.sqlite (toString error))
  let result ← try action.run conn catch error => pure (.error (.sqlite (toString error)))
  match result with
  | .error error =>
    try conn.raw.exec "ROLLBACK" catch _ => pure ()
    return .error error
  | .ok value =>
    try
      conn.raw.exec "COMMIT"
      return .ok value
    catch error =>
      try conn.raw.exec "ROLLBACK" catch _ => pure ()
      return .error (.sqlite (toString error))

private def requireDb (action : IO (Except LeanDb.DbError α)) : IO α := do
  match ← action with
  | .ok value => pure value
  | .error error => throw (IO.userError (toString error))

structure Store where
  private mk ::
  private connection : Std.Mutex LeanDb.Conn

def Store.open (path : System.FilePath) : IO Store := do
  let conn ← requireDb (LeanDb.openDb path (LeanDb.Entity.specs TicketRow))
  conn.raw.exec "PRAGMA busy_timeout = 5000"
  conn.raw.exec s!"CREATE UNIQUE INDEX IF NOT EXISTS tickets_public_identity ON {LeanDb.quoteIdent (LeanDb.Entity.tableName TicketRow)} (publicScope, publicKey)"
  requireDb <| transaction conn do
    if (← LeanDb.fetchAll TicketRow).isEmpty then
      let tickets ← LeanDb.DbM.ofExcept (seed.mapError (fun errors =>
        LeanDb.DbError.decode "seed" "tickets" (reprStr errors)))
      for ticket in tickets do discard <| LeanDb.insert TicketRow (TicketRow.ofSummary ticket)
  pure ⟨← Std.Mutex.new conn⟩

def Store.list (store : Store) : IO (Array TicketSummary) :=
  store.connection.atomically fun ref => do
    let conn ← ref.get
    requireDb <| (do (← LeanDb.fetchAll TicketRow).mapM storedSummary).run conn

def Store.save (store : Store) (input : SaveTicket) : IO (Except SaveError TicketSummary) :=
  store.connection.atomically fun ref => do
    -- Direct native callers also use the domain validator. Wire callers already decoded it.
    if let .error error := Title.parse input.title.value then
      throw (IO.userError (TitleError.message error))
    requireDb <| transaction (← ref.get) (saveCurrent input)

def Store.service (store : Store) : TicketService IO := ⟨store.list, store.save⟩

/-- Test setup for a nonnumeric public key; never exposed by the HTTP router. -/
def Store.insertFixture (store : Store) (ticket : TicketSummary) : IO Unit :=
  store.connection.atomically fun ref => do
    requireDb <| transaction (← ref.get) do
      discard <| LeanDb.insert TicketRow (TicketRow.ofSummary ticket)

end NativeTickets
