import LeanApp.Domain

/-! # The domain vocabulary, without the milestone-1 names

```
import LeanApp.Core
open LeanApp.Core

structure Member where
  name  : Name
  email : Email
  deriving Entity

constraint Member.uniqueEmail : unique email

structure Patron where      -- the app's own actor type; no library `SignedIn`/`Viewer` in scope
  private mk ::
  id : Ref Member
  deriving Principal

def lookUp (email : Email) : ReadOp Empty (Option (Row Member)) := Member.findBy email
```

`open LeanApp.Core` brings in the authored surface: `Op`, `ReadOp`, `DB`, `Query`, `Ref`,
`Row T`, `Time`, `Now`, `Clock.now`, `require`, the checked scalars, `Password`/`PasswordHash`/
`Session`/`Auth.startSession`, `Entity`, `Changes`, `Principal`, `LinkKey`, `Query.linkField`,
and `Api`/`Endpoint`/`post`/`get`. The declaration commands (`constraint`, `internal`, `link`,
`credential`, `deriving instance Changes (except := …)`, `def api : Api := […]`) are global.

`LeanApp.Domain` keeps the milestone-1 surface (`SignedIn`, `Viewer`, `policy%`, …) for code
written against it. Open one of the two, not both (`Row T` is defined in each). -/

namespace LeanApp.Core

export LeanApp.Domain (
  Op ReadOp DB Query OpScope Time Time.format Now Clock.now Op.mapError ReadOp.mapError
  Ref Ref.parse Name Name.parse Title Title.parse Text Text.parse Email Email.parse
  Password Password.parse Password.hash PasswordHash Session Session.profile
  Instant Instant.ofEpochSeconds Instant.parse Instant.format Instant.rfc3339
  Auth.startSession
  Entity Domain Changes Principal HasRow LinkKey CredentialLink
  Query.linkField
  Api Endpoint AnyEndpoint post get)

/-- `Row T` is the entity's row view (its fields and `id`). -/
scoped syntax (name := rowType) "Row " term:max : term

open Lean Elab Term Meta in
elab_rules : term
  | `(rowType| Row $target:term) => do
    let ty ← elabType target
    let rowView ← mkFreshExprMVar (some (.forallE `Scope (.sort 1) (.sort 1) .default))
    match ← synthInstance? (mkApp2 (mkConst ``LeanApp.Domain.HasRow) ty rowView) with
    | some _ => return mkApp (← instantiateMVars rowView) (mkConst ``LeanApp.Domain.OpScope)
    | none => throwError "`Row {ty}`: {ty} is not an entity (add `deriving Entity`)"

end LeanApp.Core
