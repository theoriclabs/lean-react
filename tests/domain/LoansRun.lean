/- The generality fixture on Memory, with populated state: every feature the post uses,
   on an unrelated domain (lending library). -/
import tests.domain.Loans
import LeanApp.Domain.Memory
open LeanApp.Domain Ontology Loans

namespace LoansRun

private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw (IO.userError ("FAIL: " ++ label))
private def ok [Repr E] (value : Except E A) : IO A :=
  match value with | .ok value => pure value | .error error => throw (IO.userError (reprStr error))
private def parsed (value : Validation A) : IO A :=
  match value with | .ok value => pure value | .error _ => throw (IO.userError "fixture value rejected")
private def run (op : Op ε α) (store : Memory.Store) : IO (Except ε α × Memory.Store) :=
  ok (Memory.command (op : Flow .command OpScope ε α) store)
private def read (op : ReadOp ε α) (store : Memory.Store) : IO (Except ε α) := do
  let (result, _) ← ok (Memory.read (op : Flow .query OpScope ε α) store)
  return result
private def value [Repr ε] (result : Except ε α × Memory.Store) : IO (α × Memory.Store) := do
  return (← ok result.1, result.2)
private def failsWith [BEq ε] (result : Except ε α) (expected : ε) : Bool :=
  match result with | .error error => error == expected | .ok _ => false
private def rows (store : Memory.Store) (entity : String) : Nat :=
  (store.rows.filter (·.1.entity.name == "Loans." ++ entity)).length

deriving instance BEq, Repr for RegisterError
deriving instance BEq, Repr for LogInError
deriving instance BEq, Repr for AddBookError
deriving instance BEq, Repr for BorrowError
deriving instance BEq, Repr for GetBookError
deriving instance BEq, Repr for RetireError
deriving instance BEq, Repr for EditBookError
instance : Repr Session := ⟨fun _ _ => "session"⟩

private def patron (store : Memory.Store) (id : Ref Member) : IO Patron := do
  let (row, _) ← ok ((Memory.lookup (Scope := OpScope) id).run store)
  match row with
  | some row => pure (Principal.trusted row.id row.value)
  | none => throw (IO.userError "no such member")

private def borrowers (page : BookPage) : Option (List String) :=
  match page.history with
  | .visible list => some (list.map (·.name.value))
  | .hidden => none

def main : IO Unit := do
  let initial : Memory.Store := { now := ← parsed (Instant.ofEpochSeconds 1000) }
  let password ← parsed (Password.parse "correct horse battery")
  let member := fun (name email : String) (store : Memory.Store) => do
    value (← run (register (← parsed (Name.parse name)) (← parsed (Email.parse email)) password) store)
  -- Auth: registration is one transaction; a duplicate email is the authored error.
  let (_, store) ← member "Rui" "rui@example.org" initial
  let (_, store) ← member "Sol" "sol@example.org" store
  let (dup, after) ← run (register (← parsed (Name.parse "Rui 2")) (← parsed (Email.parse "rui@example.org")) password) store
  check "duplicate email → alreadyRegistered, nothing written" (failsWith dup .alreadyRegistered && rows after "Member" == 2 && rows after "Login" == 2)
  let (wrong, _) ← run (logIn (← parsed (Email.parse "rui@example.org")) (← parsed (Password.parse "wrong password!"))) store
  check "wrong password → badCredentials" (failsWith wrong .badCredentials)
  let (unknown, _) ← run (logIn (← parsed (Email.parse "nobody@example.org")) password) store
  check "unknown email → the same error" (failsWith unknown .badCredentials)
  let (_, _) ← value (← run (logIn (← parsed (Email.parse "rui@example.org")) password) store)
  -- A librarian, seeded directly (no endpoint makes one).
  let lenaName ← parsed (Name.parse "Lena")
  let lenaEmail ← parsed (Email.parse "lena@example.org")
  let (lenaId, store) ← value (← run (Member.insert { name := lenaName, email := lenaEmail, role := .librarian }) store)
  let lenaId ← ok (lenaId.mapError fun _ => "conflict")
  let lena ← patron store lenaId
  let ruiRow ← ok (← read (Member.findBy (← parsed (Email.parse "rui@example.org")) : ReadOp Empty _) store)
  let some ruiRow := ruiRow | throw (IO.userError "Rui missing")
  let solRow ← ok (← read (Member.findBy (← parsed (Email.parse "sol@example.org")) : ReadOp Empty _) store)
  let some solRow := solRow | throw (IO.userError "Sol missing")
  let rui ← patron store ruiRow.id
  let sol ← patron store solRow.id
  -- A rule that takes a proof: only librarians add books.
  let book := fun (who : Patron) (title : String) (store : Memory.Store) => do
    run (addBook who (← parsed (Title.parse title)) (← parsed (Text.parse ""))) store
  let (denied, _) ← book rui "Dune" store
  check "readers cannot add books" (failsWith denied .notLibrarian)
  let (dune, store) ← value (← book lena "Dune" store)
  let (emma, store) ← value (← book lena "Emma" store)
  -- Composite unique (book, member): borrowing twice is the authored error.
  let (_, store) ← value (← run (borrow sol dune) store)
  let (_, store) ← value (← run (borrow rui dune) store)
  let (twice, _) ← run (borrow rui dune) store
  check "one active loan per (book, member)" (failsWith twice .alreadyBorrowed)
  let (_, store) ← value (← run (borrow rui emma) store)
  check "three loans" (rows store "Loan" == 3)
  -- ReadOp + link join: librarians see the history (by member id), readers do not.
  let page ← ok (← read (getBook (some lena) dune) store)
  check "history: names by member id" (borrowers page == some ["Rui", "Sol"])
  let hidden ← ok (← read (getBook (some rui) dune) store)
  check "readers see no history" (borrowers hidden == none)
  check "anonymous sees no history" (borrowers (← ok (← read (getBook none dune) store)) == none)
  -- Changes: an edit cannot touch `addedBy`.
  let changes : Book.Changes := { title := ← parsed (Title.parse "Dune (2nd ed.)"), notes := ← parsed (Text.parse "Hardcover") }
  let (notLib, _) ← run (editBook rui dune changes) store
  check "readers cannot edit" (failsWith notLib .notLibrarian)
  let (_, store) ← value (← run (editBook lena dune changes) store)
  let edited ← ok (← read (getBook (some lena) dune) store)
  check "edit applied" (edited.title.value == "Dune (2nd ed.)" && edited.notes.value == "Hardcover")
  -- Cascade: retiring a book removes exactly its loans.
  let (refused, _) ← run (retire sol dune) store
  check "readers cannot retire" (failsWith refused .notLibrarian)
  let (_, after) ← value (← run (retire lena dune) store)
  check "book gone" (rows after "Book" == 1 && failsWith (← read (getBook none dune) after) .notFound)
  check "its two loans went with it; the other stayed" (rows after "Loan" == 1)
  let (gone, _) ← run (borrow sol dune) after
  check "borrowing a retired book → notFound" (failsWith gone .notFound)
  IO.println "PASS loans (generality): unique (book, member), cascade 3 → 1, link history by id, internal raw ops, Changes, librarian proof, ReadOp, credential auth"

end LoansRun

def main := LoansRun.main
