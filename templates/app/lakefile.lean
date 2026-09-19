import Lake
open Lake DSL

/-! The portable package: the domain, its public contracts and the LeanReact screen.
Nothing here depends on SQLite, OpenSSL or a native HTTP stack. -/
package {{name}} where
  version := v!"0.1.0"

/-- LeanReact and LeanApp, pinned to the lean-react commit this project was scaffolded from.
`-Kleanreact=PATH` builds against a local checkout instead (`LEANAPP_LEANREACT_SOURCE` for the
npm scripts); never commit a manifest that records such a path. -/
@[package_dep] def leanreact : Dependency := {
  name := `leanreact
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leanreact with
    | some path => .path path
    | none => .git "{{leanreactUrl}}" (some "{{leanreactRev}}") none
}

@[default_target]
lean_lib {{Name}}
