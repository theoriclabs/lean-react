import Lake

open Lake DSL

/-- Explicit prefix on any platform; Homebrew default on macOS, system paths on Linux. -/
def authOpenSSLPrefix : Option String :=
  (get_config? openssl).or (if System.Platform.isOSX then some "/opt/homebrew/opt/openssl@3" else none)

def authCryptoLinkArgs : Array String :=
  (match authOpenSSLPrefix with
    | some dir => #["-L" ++ dir ++ "/lib", "-Wl,-rpath," ++ dir ++ "/lib"] ++
        (if System.Platform.isOSX then #[] else
          #["-L" ++ dir ++ "/lib64", "-Wl,-rpath," ++ dir ++ "/lib64"])
    | none => #[]) ++ #["-lcrypto"]

package leanapp_native where
  version := v!"0.2.0-rc.1"
  moreLinkArgs := authCryptoLinkArgs

/-- The portable workspace this adapter belongs to. -/
require leanreact from (get_config? leanreact).getD "../.."

/-! Published pins (LA-12). Every native dependency is fetched from its immutable
Git revision by default, so a fresh clone builds with no sibling checkouts.
`-Kleandb=PATH`, `-Kleanhttp=PATH`, `-Kleanws=PATH` and `-Kleansqlite=PATH`
override a pin with a local source tree for development; the committed manifest
must never record such a path (`npm run test:manifest`). -/

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

/-- `Handshake.Reject.unauthorized` (401 at upgrade, LA-17) landed after v0.1.0. -/
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

target leanapp_auth.o pkg : System.FilePath := do
  let src ← inputTextFile (pkg.dir / "bindings" / "leanapp_auth.c")
  let includes := #["-I", (← getLeanIncludeDir).toString] ++
    (match authOpenSSLPrefix with | some p => #["-I", p ++ "/include"] | none => #[])
  buildO (pkg.buildDir / "leanapp_auth.o") src #[]
    (traceArgs := includes ++ #["-fPIC", "-std=c11", "-Wall", "-Wextra", "-Werror"])
    (extraDepTrace := getLeanTrace)

extern_lib leanapp_auth pkg := do
  let obj ← leanapp_auth.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "leanapp_auth") #[obj]

@[default_target]
lean_lib LeanAppNative where
  needs := #[leanapp_auth]

lean_exe leanapp_crypto_checks where
  root := `CryptoChecks

lean_exe leanapp_auth_checks where
  root := `AuthChecks

lean_exe leanapp_auth_demo where
  root := `AuthMain

lean_exe leanapp_cafe where
  root := `CafeMain

lean_exe leanapp_notes where
  root := `NotesMain

lean_exe leanapp_notes_checks where
  root := `NotesChecks

lean_exe leanapp_storage_checks where
  root := `StorageChecks

lean_exe leanapp_http_checks where
  root := `HttpChecks

/-- Native managed dispatch checks against the integrated Runtime.withConnection API. -/
lean_exe leanapp_managed_checks where
  root := `ManagedChecks

lean_exe leanapp_channel_checks where
  root := `ChannelChecks

lean_exe leanapp_job_checks where
  root := `JobChecks
