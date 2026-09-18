import AclFixture

/-- Expected to exit nonzero: the edit binding lost its role check, so the matrix reports it. -/
def main : IO Unit := do
  let .ok app := AclFixture.application (weakened := true) | throw (IO.userError "invalid fixture")
  let failures := AclFixture.failures app
  if failures.isEmpty then
    IO.println "PASS: weakened application passed the matrix (unexpected)"
  else
    throw (IO.userError s!"acl.matrix_failed\n{LeanApp.Testing.report failures}")
