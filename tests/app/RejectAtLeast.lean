import LeanApp
import AclFixture

open LeanApp LeanApp.Policy Contract Ontology

/-! Expected not to typecheck: a `requireAtLeast .viewer` policy cannot feed an
    `.editor` handler. The evidence types are distinct. -/
def bad (edit : Operation .command String String String) :
    BindingE AclFixture.Fixture AclFixture.ReadOp AclFixture.WriteOp edit
      (AtLeast AclFixture.Role .editor) where
  policy := requireAtLeast AclFixture.Role.viewer AclFixture.roleOf
  http := { path := "/doc/edit" }
  handler := fun _ cap _ev text => do
    AclFixture.commands.write (.replace text)
    return .ok text
