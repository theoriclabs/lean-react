import LeanAppNative.Auth.Crypto

open LeanAppNative.Auth.Crypto

private def check (b : Bool) (label : String) : IO Unit :=
  unless b do throw (IO.userError ("crypto check failed: " ++ label))

private def rejects (action : IO α) : IO Unit := do
  let rejected ← try let _ ← action; pure false catch _ => pure true
  check rejected "input bound"

private def repeated (c : Char) (n : Nat) : String := String.ofList (List.replicate n c)

private def canonicalToken (s : String) : Bool :=
  s.utf8ByteSize == 64 && s.toList.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f'))

def main : IO Unit := do
  let actual ← version
  check (actual.startsWith "OpenSSL ") "runtime version"
  IO.println actual
  let password := "café 東京 😀\u0000suffix"
  let first ← hashPassword password
  let second ← hashPassword password
  check (first != second) "fresh salt"
  check (first.startsWith "$leanapp$scrypt$v1$N=131072$r=8$p=1$") "canonical record prefix"
  check (← verifyPassword password first) "unicode and NUL password"
  check (← verifyPassword password second) "second salted record"
  check (!(← verifyPassword "café 東京 😀" first)) "NUL not truncated"
  check (!(← verifyPassword "wrong" first)) "wrong password"
  for password in ["a", "\u0000", repeated 'x' 1024, repeated 'é' 512] do
    let encoded ← hashPassword password
    check (← verifyPassword password encoded) "password boundary"
  for password in ["", repeated 'x' 1025, repeated 'é' 513] do
    rejects (hashPassword password)
    check (!(← verifyPassword password first)) "verify password bound"
  let recordPrefix := "$leanapp$scrypt$v1$N=131072$r=8$p=1$"
  for bad in ["", "scrypt", String.ofList (first.toList.take (first.length - 1)),
      first ++ "x", first ++ "\u0000", repeated 'x' 10000,
      first.replace "v1" "v2", first.replace "131072" "000002",
      first.replace "r=8" "r=1", first.replace "p=1" "p=2",
      recordPrefix ++ repeated 'A' 32 ++ "$" ++ repeated '0' 64,
      recordPrefix ++ repeated '0' 32 ++ ":" ++ repeated '0' 64,
      recordPrefix ++ repeated '0' 32 ++ "$" ++ repeated 'g' 64,
      recordPrefix ++ repeated '0' 31 ++ "\u0000$" ++ repeated '0' 64] do
    check (!(← verifyPassword "a" bad)) "malformed encoding"
  check ((← digestToken "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") "SHA256 vector"
  check ((← digestToken "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") "empty digest"
  check ((← digestToken "a\u0000b") != (← digestToken "a")) "digest NUL length"
  check (canonicalToken (← digestToken (repeated 'x' 1024))) "digest boundary"
  rejects (digestToken (repeated 'x' 1025))
  let mut seen : List String := []
  for _ in [:32] do
    let token ← randomToken
    check (canonicalToken token && !seen.contains token) "random token canonical and unique"
    seen := token :: seen
  check (← constantTimeEqual "" "") "empty comparison"
  check (← constantTimeEqual "é\u0000x" "é\u0000x") "NUL comparison"
  check (!(← constantTimeEqual "a\u0000b" "a\u0000c")) "comparison content"
  check (!(← constantTimeEqual "a" "a\u0000")) "comparison length"
  check (← constantTimeEqual (repeated 'x' 1024) (repeated 'x' 1024)) "comparison boundary"
  rejects (constantTimeEqual (repeated 'x' 1025) "")
  rejects (constantTimeEqual "" (repeated 'x' 1025))
  IO.println "PASS crypto: production scrypt, strict records, UTF8/NUL, bounds, EVP SHA256, random tokens, constant-time comparison"
