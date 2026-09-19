import Lake
open Lake DSL

/-- OpenSSL for the auth bindings: Homebrew's prefix on macOS, system paths on Linux, or
`-Kopenssl=PREFIX` (`LEANAPP_OPENSSL_PREFIX` for the npm scripts). -/
def openSSLPrefix : Option String :=
  (get_config? openssl).or (if System.Platform.isOSX then some "/opt/homebrew/opt/openssl@3" else none)

def cryptoLinkArgs : Array String :=
  (match openSSLPrefix with
    | some dir => #["-L" ++ dir ++ "/lib", "-Wl,-rpath," ++ dir ++ "/lib"] ++
        (if System.Platform.isOSX then #[] else #["-L" ++ dir ++ "/lib64", "-Wl,-rpath," ++ dir ++ "/lib64"])
    | none => #[]) ++ #["-lcrypto"]

/-! The native package: storage, application bindings, the auth host and the executable.
It shares the portable package's dependency directory so every pin is cloned once. -/
package {{name}}_native where
  version := v!"0.1.0"
  packagesDir := "../.lake/packages"
  moreLinkArgs := cryptoLinkArgs

require {{name}} from ".."

/-- Same pin as the portable package; `-Kleanreact=PATH` overrides both. -/
@[package_dep] def leanreact : Dependency := {
  name := `leanreact
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leanreact with
    | some path => .path path
    | none => .git "{{leanreactUrl}}" (some "{{leanreactRev}}") none
}

/-- The native adapter lives inside the lean-react repository, so it follows `leanreact`'s source. -/
@[package_dep] def leanapp_native : Dependency := {
  name := `leanapp_native
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leanapp_native, get_config? leanreact with
    | some path, _ => .path path
    | none, some checkout => .path (checkout ++ "/adapters/native")
    | none, none => .path "../.lake/packages/leanreact/adapters/native"
}

/-! Immutable Git pins of the native dependencies (LA-12). `-K<name>=PATH` overrides one with a
local source tree; never commit a manifest that records such a path. -/

@[package_dep] def leandb : Dependency := {
  name := `leandb
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leandb with
    | some path => .path path
    | none => .git "https://github.com/theoriclabs/LeanDB" (some "v0.4.0") none
}

@[package_dep] def leanhttp : Dependency := {
  name := `leanhttp
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leanhttp with
    | some path => .path path
    | none => .git "https://github.com/theoriclabs/leanhttp" (some "v0.3.1") none
}

@[package_dep] def leanws : Dependency := {
  name := `leanws
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leanws with
    | some path => .path path
    | none => .git "https://github.com/theoriclabs/leanws" (some "40900ccb00e04186360ba0a235c560517b7ecb57") none
}

@[package_dep] def leansqlite : Dependency := {
  name := `leansqlite
  scope := ""
  version := .none
  opts := {}
  src? := some <| match get_config? leansqlite with
    | some path => .path path
    | none => .git "https://github.com/leanprover/leansqlite" (some "0be4df908d1a8e75b58961041e2b4973692623df") none
}

@[default_target]
lean_lib {{Name}}Native

/-- The application process: auth, host, lifecycle. -/
@[default_target]
lean_exe {{name}}_server where
  root := `Main

/-- Storage, handler and access-control checks over a temporary database. -/
@[default_target]
lean_exe {{name}}_checks where
  root := `Checks
