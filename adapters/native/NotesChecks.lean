import LeanAppNative.Notes

open LeanAppNative LeanAppNative.Auth LeanApp Ontology

private def check (label : String) (test : Bool) : IO Unit := do
  unless test do throw (IO.userError s!"FAIL notes: {label}")
  IO.println s!"PASS notes: {label}"

private def ok (result : Except Auth.Error α) : IO α :=
  match result with | .ok v => pure v | .error e => throw (IO.userError s!"unexpected auth failure: {repr e}")

def main : IO Unit := IO.FS.withTempDir fun dir => do
  let inst := LeanDb.Instance.ofPath (dir / "notes.sqlite")
  let .ok session ← LeanDb.Cli.Session.open Notes.base inst | throw (IO.userError "session")
  let runtime ← LeanDb.Runtime.Service.new Notes.base inst session true
  let clock ← IO.mkRef 1000
  let auth ← ok (← Auth.Service.new runtime clock.get 60)
  try
    let alice ← ok (← auth.signup "alice_notes" "a sufficiently long test password")
    let bob ← ok (← auth.signup "bob_notes" "a sufficiently long test password")
    discard <| ok (← auth.setAccess bob.user.actor alice.user.tenant true)
    let bob ← ok (← auth.login "bob_notes" "a sufficiently long test password")
    check "two actual accounts share a tenant but not an owner" (bob.user.tenant == alice.user.tenant && bob.user.actor != alice.user.actor)
    let host ← Notes.host auth "https://example.test"
    let call := fun (login : Auth.Issued) (name : String) (input : Lean.Json) => do
      let body := Lean.Json.mkObj [
        ("operation", .mkObj [("namespace", .str "notes"), ("name", .str name), ("version", .str "1")]),
        ("kind", .str (if name == "lab" then "command" else "query")), ("input", input)]
      host.dispatch ⟨"POST", "/api/notes/" ++ name, [
        ("origin", "https://example.test"), ("content-type", "application/json"),
        ("x-leanapp-request", "1"), ("cookie", "__Host-leanapp_session=" ++ login.token),
        ("x-csrf-token", login.csrf)], body.compress⟩
    for login in [alice, bob] do
      check "fixture setup" ((← call login "lab" .null).reply.status == 200)
    let criteria : Notes.Criteria := {}
    let input := (Wire.codec (α := Notes.Criteria)).encode criteria
    let a ← call alice "list" input
    let b ← call bob "list" input
    check "same-tenant accounts receive their own two notes" (a.reply.status == 200 && b.reply.status == 200 && a.reply.body != b.reply.body)
    let .ok av := (Wire.codec (α := Notes.Answer)).decode (← IO.ofExcept ((a.reply.body.getObjVal? "value").mapError IO.userError))
      | throw (IO.userError "answer decode")
    let .ok bv := (Wire.codec (α := Notes.Answer)).decode (← IO.ofExcept ((b.reply.body.getObjVal? "value").mapError IO.userError))
      | throw (IO.userError "answer decode")
    check "same-tenant row IDs are disjoint" (av.notes.length == 2 && bv.notes.length == 2 && av.notes.all (fun x => bv.notes.all (fun y => x.id != y.id)))
    let foreignInput := (Wire.codec (α := Notes.Criteria)).encode { criteria with id := bv.notes.head?.map (·.id) }
    check "same-tenant actual account lookup is denied" ((← call alice "lookup" foreignInput).reply.status == 404)
    let conn ← session.conn.get
    let p : PrivateNotes.Principal := ⟨alice.user.actor, alice.user.tenant, alice.user.generation⟩
    let facts : PrivateNotes.SessionFacts := ⟨p.actor, p.tenant, p.generation, p.generation, true, 1060, 1000⟩
    let .ok grant := PrivateNotes.authorize Unit facts p | throw (IO.userError "grant")
    let alive ← IO.mkRef false
    let rejected ← try
      discard <| Notes.protectedRead conn alive grant .list {}
      pure false
    catch _ => pure true
    check "retired native lease rejects even a well-typed old grant" rejected
    let failed ← auth.withAuthenticatedTransaction alice.token alice.csrf "throw" fun conn _ _ _ _ => do
      conn.raw.exec "CREATE TABLE rollback_marker (n INTEGER)"
      throw (IO.userError "deliberate callback failure")
      pure ()
    check "callback failure is sanitized" (!failed.isOk)
    let subsequent ← auth.withAuthenticatedTransaction alice.token alice.csrf "after" fun conn _ _ _ _ => do
      let stmt ← conn.raw.prepare "SELECT count(*) FROM sqlite_master WHERE name = 'rollback_marker'"
      unless ← stmt.step do throw (IO.userError "count")
      pure ((← stmt.columnInt64 0) == 0)
    check "transaction rolls back and the connection remains usable" (← ok subsequent)
    discard <| ok (← auth.setAccess alice.user.actor alice.user.tenant false)
    check "committed revocation denies the next request" ((← call alice "list" input).reply.status == 401)
  finally
    discard <| runtime.close
