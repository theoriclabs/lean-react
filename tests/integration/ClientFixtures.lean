import Examples.Tickets.Contracts

/-! Wire fixtures produced by the Lean codecs, one JSON document on stdout. The generated
JavaScript client must decode each and re-encode it identically after canonical key ordering. -/
open Ontology Contract Examples.Tickets Examples.Tickets.Contracts

def require (result : Except ε α) (label : String) : IO α :=
  match result with
  | .ok value => pure value
  | .error _ => throw (IO.userError s!"invalid fixture: {label}")

def main : IO Unit := do
  let ops ← require publicOperations "operations"
  let tickets ← require seed "seed"
  let id ← require (EntityId.parse "tickets-demo" "public-ticket-9007199254740993") "id"
  let user ← require (EntityId.parse (α := User) "directory-demo" "user-17") "user"
  let huge := 2^128 + 9007199254740993
  let current : TicketSummary := ⟨id, huge, ⟨⟨"Native integration fixture"⟩, .backlog, some user⟩⟩
  let input : SaveTicket := ⟨id, huge, ⟨"Saved with shared domain rules"⟩, .inProgress⟩
  let invalid := (ops.codecs.saveInput.encode input).setObjVal! "title" (.str "")
  let .error errors := ops.codecs.saveInput.decode invalid | throw (IO.userError "empty title must fail")
  let json := Lean.Json.mkObj [
    ("manifest", ops.manifest),
    ("list", .mkObj [("input", .null), ("output", ops.list.outputCodec.encode (tickets.push current))]),
    ("save", .mkObj [
      ("input", ops.codecs.saveInput.encode input),
      ("output", ops.codecs.summary.encode current),
      ("errors", .arr #[ops.codecs.saveError.encode .notFound, ops.codecs.saveError.encode (.conflict current)]),
      ("statuses", .arr #[.num 404, .num 409]),
      ("success", successResponse ops saveIdentity (ops.codecs.summary.encode current)),
      ("domainError", domainResponse ops saveIdentity (.conflict current)),
      ("decodeError", decodeErrorResponse ops errors)])]
  IO.println json.compress
