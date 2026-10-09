import LeanReact.Domain
import LeanReact.Compiler
import LeanContract.Browser
import LeanApi.Native

/-! # Full-stack serving: an `App`'s api and its pages

```lean
import Shop.Views          -- `def app : App where api := api; pages := [...]`
import LeanReact.Server

app% shop where
  app := app
  migrations := [addShelf := Book.addField shelf (fill := .general)]

def main (args : List String) : IO UInt32 := shop.main args
```

`app% Name where app := X` serves a LeanReact `App` natively, on LeanAPI's native app:

* `X.api` is served as the HTTP routes by LeanAPI's `declareApiApp`, under the name
  `Name.api` (its schema is `Name.api.Database`). Accounts come from the domain: the one
  entity declared with `credential C.profile C.hash` next to the api; with none, the app has
  no accounts (and its operations take no actor).
* `X.pages` are served as HTML routes: each page path returns the same HTML shell (title,
  bootstrap data, `<script src="/assets/app.mjs">`), and the browser mounts `App.component X`,
  which routes every page itself. A page that shares a GET endpoint's path is negotiated by
  LeanAPI (`Accept: text/html` gets the page).
* At elaboration, `app%` writes the LeanJS module of the browser side,
  `.lake/leanreact-browser/<Name>/domain.mjs`, relative to the build workspace.
* `Name.main` runs LeanAPI's `runApp`: under `LEANAPP_EMIT_CLIENT` it writes the generated
  client and `pages.json` next to it; otherwise it gates the database and serves.

The browser bundle (`app.mjs`) is built from those files, the entry `engine/browser/App.mjs`
and the LeanReact/LeanContract runtime by a Lake target in the app's own lakefile (see
`scripts/browser-target.py`); `lake exe Name` needs that target, so it builds the bundle as a
dependency. At run time the server looks for the bundle in `LEANREACT_BROWSER_DIR`, else in
`<workspace>/.lake/leanreact-browser/<Name>` (the workspace is found from the executable's own
path, `.lake/build/bin/<exe>`), else relative to the working directory. An api-only app never
imports this module. -/

namespace LeanReact.Server
open Lean LeanApi LeanApi.Native LeanDb Ontology

/-- What the browser host passes to the mounted `App` (compiled with LeanJS). Commands reload
the page's data through the `App` itself, so `refresh` is a no-op here. -/
def shellProps (generation : Nat) (currentGeneration : LeanReact.Action Nat)
    (framework : Contract.CallError Empty → LeanReact.Action Unit) (navigate : String → LeanReact.Action Unit)
    (authenticationChanged : LeanReact.Action Unit) : LeanReact.Domain.ShellProps :=
  { generation, currentGeneration, framework, navigate, refresh := pure (), authenticationChanged }

def appProps (shell : LeanReact.Domain.ShellProps) (location : String) (actor : Option String) :
    LeanReact.Domain.AppProps := { shell, location, actor }

/-- The browser side of a full-stack app. -/
structure Browser where
  /-- The `domain.mjs` export mounting the app: `client → requestClient → Component AppProps`. -/
  component : String
  /-- The bundle's directory, relative to the build workspace. -/
  directory : System.FilePath
  /-- The HTML title: the root module of the `App`'s declaration (`Shop.Views` gives `Shop`). -/
  title : String
  /-- The `App`'s page templates (`/books/:book`), served as HTML routes. -/
  pages : List String

private def identityJson (identity : Contract.OperationId) : Lean.Json :=
  .mkObj [("namespace", .str identity.namespaceName), ("name", .str identity.name), ("version", .str identity.version)]

/-- `pages.json`, read by the browser entry: what to mount and which calls sign in. -/
def Browser.assembly (browser : Browser) (authentication : List Contract.OperationId) : Lean.Json :=
  .mkObj [
    ("app", .mkObj [("component", .str browser.component),
      ("shell", .str (``shellProps).toString), ("props", .str (``appProps).toString)]),
    ("authentication", .arr (authentication.map identityJson).toArray),
    ("pages", .arr (browser.pages.map Lean.Json.str).toArray)]

/-- Where the compiled bundle is: see the module documentation. -/
def Browser.locate (browser : Browser) : IO System.FilePath := do
  if let some dir ← IO.getEnv "LEANREACT_BROWSER_DIR" then return dir
  let exe ← IO.appPath
  let workspace := exe.parent >>= (·.parent) >>= (·.parent) >>= (·.parent)
  let candidates := (workspace.map (· / browser.directory)).toList ++ [browser.directory]
  for candidate in candidates do
    if ← (candidate / "app.mjs").pathExists then return candidate
  throw (IO.userError s!"compiled browser bundle missing (looked for app.mjs in {candidates}); \
    build the app's browser target or set LEANREACT_BROWSER_DIR")

/-- Application-owned HTML shell settings. Raw CSS and head HTML are trusted, not escaped. -/
structure Shell where
  title : Option String := none
  style : Option String := none
  /-- URLs under /assets, relative to the browser bundle directory. -/
  stylesheets : List String := []
  /-- Label and path pairs; none retains the static page paths, some [] omits the nav. -/
  navigation : Option (List (String × String)) := none
  head : String := ""

/-- The HTML shell every page shares: title, the static page paths as navigation, the
bootstrap data and the compiled browser entry. -/
def html (title : String) (navigation : List String) (bootstrap : Lean.Json) (shell : Shell := {}) : Res :=
  let escape := fun (text : String) => ((text.replace "&" "&amp;").replace "<" "&lt;").replace "\"" "&quot;"
  let escaped := bootstrap.compress.replace "<" "\\u003c"
  let links := String.join ((shell.navigation.getD (navigation.map fun path => (path, path))).map
    fun (label, path) => "<a href=\"" ++ escape path ++ "\">" ++ escape label ++ "</a>")
  let nav := if shell.navigation == some [] then "" else "<nav>" ++ links ++ "</nav>"
  let stylesheets := String.join (shell.stylesheets.map fun path =>
    "<link rel=\"stylesheet\" href=\"" ++ escape path ++ "\">")
  (Res.html ("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" ++ escape (shell.title.getD title) ++ "</title><style>" ++ shell.style.getD "body{font:16px system-ui;max-width:42rem;margin:3rem auto;padding:1rem}label{display:block;margin:1rem 0}input,select,textarea,button{font:inherit;padding:.5rem}button{margin:.5rem}nav{display:flex;gap:1rem}[role=alert]{color:#a21}" ++ "</style>" ++ stylesheets ++ shell.head ++ "</head><body>" ++ nav ++ "<main id=\"root\"></main><script type=\"application/json\" id=\"leanapp-bootstrap\">" ++ escaped ++ "</script><script type=\"module\" src=\"/assets/app.mjs\"></script></body></html>")).setHeader "cache-control" "private, no-store"

/-- The compiled bundle, as a GET route. -/
def asset (bundle : System.FilePath) : LeanApi.Native.PageRoute :=
  { path := "/assets/app.mjs", handler := fun _ => do
      return (Res.bytes (← IO.FS.readBinFile (bundle / "app.mjs")) "text/javascript; charset=utf-8").setHeader
        "cache-control" "private, no-store" }

/-- Explicit stylesheet routes only; never expose arbitrary files outside the bundle. -/
def stylesheetAssets (bundle : System.FilePath) (shell : Shell) : List LeanApi.Native.PageRoute :=
  shell.stylesheets.map fun path =>
    { path, handler := fun _ => do
        let relative := path.drop 8 |>.toString
        unless path.startsWith "/assets/" && relative.endsWith ".css" &&
            (relative.splitOn "/").all (fun part => part != ".." && part != "." && !part.isEmpty) &&
            !relative.contains '\\' do
          return Res.text "not found" 404
        return (Res.bytes (← IO.FS.readBinFile (bundle / relative)) "text/css; charset=utf-8").setHeader
          "cache-control" "private, no-store" }

private def navigation (browser : Browser) : List String :=
  browser.pages.filter fun path => !path.contains ':'

/-- The page routes of an app with accounts: each page resolves the signed-in profile (the
same session check as the api) and hydrates it, with the CSRF cookie's name. -/
def accountPages {s Profile} [IsSchema s] [LeanDb.Model.Entity Profile] (browser : Browser)
    (bundle : System.FilePath) (context : LeanApi.Native.Context s Profile) (shell : Shell := {}) : List LeanApi.Native.PageRoute :=
  let codecs := match Contract.Http.codecs with | .ok codecs => some codecs | .error _ => none
  let failed := fun (code : String) (status : Nat) => match codecs with
    | some codecs => frameworkReply codecs (fault (Error := Empty) code status)
    | none => Res.text "internal" 500
  let page : Req → IO Res := fun req => do
    match ← context.dc.read (Read.runPrepared (do context.fresh) (fun env =>
        Auth.resolve (Scope := Unit) context.cookies env req context.store.live)) with
    | .error .busy => return failed "storage.busy" 503
    | .error .stopped | .ok (.error _) => return failed "storage.unavailable" 500
    | .ok (.ok (.error fault)) => return databaseReply fault
    | .ok (.ok (.ok (.error error))) => return match codecs with
      | some codecs => frameworkReply codecs error
      | none => Res.text "internal" 500
    | .ok (.ok (.ok (.ok actor))) =>
      let actor := actor.map (fun row => Wire.codec.encode row.id) |>.getD .null
      return html browser.title (navigation browser) (.mkObj [("actor", actor), ("csrfCookie", .str context.cookies.csrfName)]) shell
  (browser.pages.map fun path => ({ path, handler := page } : LeanApi.Native.PageRoute)) ++ [asset bundle] ++ stylesheetAssets bundle shell

/-- The page routes of an app with no accounts. -/
def publicPages (browser : Browser) (bundle : System.FilePath) (shell : Shell := {}) : List LeanApi.Native.PageRoute :=
  let page : Req → IO Res := fun _ =>
    return html browser.title (navigation browser) (.mkObj [("actor", .null), ("csrfCookie", .str "")]) shell
  (browser.pages.map fun path => ({ path, handler := page } : LeanApi.Native.PageRoute)) ++ [asset bundle] ++ stylesheetAssets bundle shell

/-- A full-stack app with accounts: LeanAPI's native app and the browser side. -/
structure AccountsApp (s Profile : Type) [IsSchema s] [LeanDb.Model.Entity Profile] : Type 1 where
  native : NativeApp s Profile
  browser : Browser

/-- A full-stack app with no accounts. -/
structure PublicPagesApp (s : Type) [IsSchema s] : Type 1 where
  native : PublicApp s
  browser : Browser

/-- The emit step: the generated client (LeanAPI) and `pages.json`. -/
def emitBrowser (client : System.FilePath → IO Unit) (browser : Browser)
    (authentication : List Contract.OperationId) (out : System.FilePath) : IO Unit := do
  client out
  IO.FS.writeFile (out / "pages.json") (browser.assembly authentication).compress

/-- The executable: `LEANAPP_EMIT_CLIENT` emits the browser's client files; `migrate --check` /
`migrate`; otherwise the startup gate, then the api and the pages. -/
def AccountsApp.main {s Profile} [IsSchema s] [LeanDb.Model.Entity Profile]
    (app : AccountsApp s Profile) (args : List String) (config : AppConfig := {}) (shell : Shell := {}) : IO UInt32 :=
  runApp s app.native.migrations (emitBrowser app.native.emitClient app.browser app.native.authOperations)
    (fun config => do
      let bundle ← app.browser.locate
      let native := { app.native with pages := accountPages app.browser bundle (shell := shell) }
      native.withService config fun _ service => LeanApi.serve service { host := config.host, port := config.port })
    args config

def PublicPagesApp.main {s} [IsSchema s] (app : PublicPagesApp s) (args : List String)
    (config : AppConfig := {}) (shell : Shell := {}) : IO UInt32 :=
  runApp s app.native.migrations (emitBrowser app.native.emitClient app.browser [])
    (fun config => do
      let bundle ← app.browser.locate
      let native := { app.native with pages := publicPages app.browser bundle shell }
      native.withService config fun service => LeanApi.serve service { host := config.host, port := config.port })
    args config

/-! ## `app% Name where app := X` -/

open Elab Command Meta

private def generated (source : String) : CommandElabM Unit := do
  match Parser.runParserCategory (← getEnv) `command source with
  | .error error => throwError "app assembly: {error}\n{source}"
  | .ok command => elabCommand command

/-- `app% Name where app := X [migrations := […]]`: serve the LeanReact `App` `X`, its api and
its pages (see the module documentation). -/
syntax (name := fullStackApp) "app% " ident " where " &"app" ":=" ident (LeanApi.Native.appMigrations)? : command

/-- The `api` of a LeanReact `App` declared as `def app : App where api := api; pages := …`. -/
def appApi (app : Lean.Name) : CommandElabM Lean.Name := do
  let info ← getConstInfo app
  unless info.type.isConstOf ``LeanReact.Domain.App do throwError "{app} is not a LeanReact `App`"
  let some value := info.value? | throwError "{app} has no definition"
  let value := value.consumeMData
  unless value.isAppOfArity ``LeanReact.Domain.App.mk 2 do
    throwError "{app} must be a structure instance `\{ api := …, pages := … }`"
  let .const api _ := (value.getArg! 0).consumeMData
    | throwError "{app}: `api` must name a declared `def … : Api`"
  return api

/-- The domain's accounts: the one entity of `domain` with a `credential` declaration
(`C.credentialLink : CredentialLink C P`), or none. -/
def domainAccounts (domain : Lean.Name) : CommandElabM (Option Accounts) := do
  let env ← getEnv
  let entities := (LeanDb.Model.Deriving.entityDeclarations.getState env).filter (·.name.getPrefix == domain)
  let credentials := entities.filter fun entry => env.contains (entry.name ++ `credentialLink)
  match credentials.toList with
  | [] => return none
  | [entry] =>
    let type := (← getConstInfo (entry.name ++ `credentialLink)).type
    unless type.isAppOfArity ``LeanApi.Core.CredentialLink 2 do
      throwError "{entry.name}.credentialLink is not a `CredentialLink`"
    let .const profile _ := type.getArg! 1 | throwError "{entry.name}.credentialLink: expected a profile entity"
    return some { profile, credential := entry.name }
  | many => throwError "the app's domain declares more than one credential: {many.map (·.name)}"

@[command_elab fullStackApp]
def elabFullStackApp : CommandElab := fun stx => withRef stx do
  let appRef := stx[5]
  let reactApp ← resolveGlobalConstNoOverload (TSyntax.mk (ks := `ident) appRef)
  let api ← withRef appRef (appApi reactApp)
  let accounts ← withRef appRef (domainAccounts api.getPrefix)
  let appName := (← getCurrNamespace) ++ stx[1].getId
  let root := fun n : Lean.Name => "_root_." ++ n.toString
  let quote := fun (text : String) => (Lean.Json.str text).compress
  -- The api, natively (LeanAPI), as `Name.api`.
  let native := appName ++ `api
  LeanApi.Native.declareApiApp native api accounts ((stx[6].getOptional?.map (·[3].getSepArgs)).getD #[]) appRef
  -- The browser side: `App.component X`, compiled by LeanJS into the bundle's directory.
  let component := appName ++ `browserApp
  generated ("def " ++ root component ++ " (client : Contract.Interpreter LeanReact.Action) " ++
    "(requestClient : LeanReact.ResourceRequest → Contract.Interpreter LeanReact.Action) : " ++
    "LeanReact.Component LeanReact.Domain.AppProps := LeanReact.Domain.App.component " ++ root reactApp ++
    " client (some requestClient)")
  let directory := ".lake/leanreact-browser/" ++ appName.toString
  liftCoreM do
    IO.FS.createDirAll directory
    LeanJS.writeModule (System.FilePath.mk directory / "domain.mjs")
      #[component, ``shellProps, ``appProps, `Contract.Browser.jsonObject, `Contract.Browser.jsonEntries,
        `Contract.Browser.jsonNumber, `Contract.Browser.frameworkError, `Contract.Browser.decodeErrors]
      (LeanReact.Compiler.options "./runtime/leanjs-react.mjs")
  let env ← getEnv
  let module := match env.getModuleIdxFor? reactApp with
    | some index => env.header.moduleNames[index.toNat]!
    | none => env.mainModule
  let browser := "{ component := " ++ quote component.toString ++ ", directory := " ++ quote directory ++
    ", title := " ++ quote module.getRoot.toString ++
    ", pages := (" ++ root reactApp ++ ").pages.map (·.path) }"
  let schema := root (native ++ `Database)
  match accounts with
  | some accounts =>
    generated ("def " ++ root appName ++ " : LeanReact.Server.AccountsApp " ++ schema ++ " " ++
      root accounts.profile ++ " := { native := " ++ root native ++ ", browser := " ++ browser ++ " }")
  | none =>
    generated ("def " ++ root appName ++ " : LeanReact.Server.PublicPagesApp " ++ schema ++
      " := { native := " ++ root native ++ ", browser := " ++ browser ++ " }")

end LeanReact.Server
