import tests.domain.PostPart1
open LeanApp.Domain
inductive LeakError where
  | notFound
def leak (party : Ref Party) : ReadOp LeakError (Row Party) := do
  let some p ← Party.find party | throw .notFound
  return p
derive_operation leak
