import {{Name}}Native.Application

open LeanAppNative LeanApp {{Name}}

private def check (label : String) (ok : Bool) : IO Unit := do
  unless ok do throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

private def expect (result : Except Auth.Error α) : IO α :=
  match result with
  | .ok value => pure value
  | .error e => throw (IO.userError s!"unexpected auth failure: {repr e}")

private def count (reply : Auth.Response) : Option Nat :=
  ((reply.reply.body.getObjVal? "value").toOption.bind fun v => (v.getArr?.toOption.map (·.size)))

/-- Storage, handlers and access control over a temporary database, without sockets. -/
def main : IO Unit := IO.FS.withTempDir fun dir => do
  let inst := LeanDb.Instance.ofPath (dir / "{{name}}.sqlite")
  let .ok runtime ← Runtime.Service.new {{Name}}Native.base inst (config := { readers := 1 })
    | throw (IO.userError "database unavailable")
  try
    let auth ← expect (← Auth.Service.new runtime)
    let host ← {{Name}}Native.host auth "https://example.test"
    let alice ← expect (← auth.signup "alice_check" "a sufficiently long passphrase")
    let bob ← expect (← auth.signup "bob_check" "a sufficiently long passphrase")
    let call := fun (session : Option Auth.Issued) (csrf : Option String) (name : String) (input : Lean.Json) => do
      let body := Lean.Json.mkObj [
        ("operation", .mkObj [("namespace", .str packageId), ("name", .str name), ("version", .str "1")]),
        ("kind", .str (if name == "add" then "command" else "query")), ("input", input)]
      let headers := [("origin", "https://example.test"), ("content-type", "application/json"), ("x-leanapp-request", "1")] ++
        (match session with
          | some s => [("cookie", "__Host-leanapp_session=" ++ s.token), ("x-csrf-token", csrf.getD s.csrf)]
          | none => [])
      host.dispatch ⟨"POST", "/api/notes/" ++ name, headers, body.compress⟩
    check "ACL: an anonymous call is refused before any handler" ((← call none none "list" .null).reply.status == 401)
    check "ACL: a wrong CSRF token is refused"
      ((← call (some alice) (some (String.ofList (List.replicate 64 '0'))) "list" .null).reply.status == 403)
    let added ← call (some alice) none "add" (.str "Buy oat milk")
    check "handler: add stores and returns the note"
      (added.reply.status == 200 &&
        ((added.reply.body.getObjVal? "value").toOption.bind fun v => (v.getObjValAs? String "title").toOption) == some "Buy oat milk")
    check "domain: an empty title is rejected by the shared parser" ((← call (some alice) none "add" (.str "")).reply.status == 400)
    check "domain: an over-long title is rejected by the shared parser"
      ((← call (some alice) none "add" (.str (String.ofList (List.replicate 121 'x')))).reply.status == 400)
    check "storage: the owner lists the note" (count (← call (some alice) none "list" .null) == some 1)
    check "ACL: another account in another tenant sees nothing" (count (← call (some bob) none "list" .null) == some 0)
    IO.println "PASS {{name}} native checks"
  finally runtime.close
