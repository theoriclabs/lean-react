import LeanReact.Core
import LeanReact.DOM

namespace LeanReact

/-! URL helpers. Portable Lean cannot yet split strings (see the LeanJS scalar-slicing work), so these
are host intrinsics in the browser (`engine/runtime/router.mjs`) with ordinary Lean reference bodies. -/

namespace Route

private def stripHash (location : String) : String :=
  match location.splitOn "#" with | head :: _ => head | [] => location

/-- `"pathname?search#hash"` → `(pathname, search)` without the `?` and hash. -/
def split (location : String) : String × String :=
  match (stripHash location).splitOn "?" with
  | [] => ("", "")
  | [path] => (path, "")
  | path :: rest => (path, String.intercalate "?" rest)

/-- Non-empty, percent-decoded path segments: `"/tickets/42/"` → `#["tickets", "42"]`. -/
def segments (path : String) : Array String :=
  ((split path).1.splitOn "/").filter (· ≠ "") |>.toArray

/-- A decimal segment as `Nat`; anything else is `none`. -/
def nat? (segment : String) : Option Nat :=
  if segment.isEmpty then none else segment.toNat?

/-- Portable: `#["tickets", "42"]` → `"/tickets/42"`; the empty array is `"/"`. -/
def join (parts : Array String) : String :=
  "/" ++ String.intercalate "/" parts.toList

end Route

namespace Query

private def hex (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

private def decodeChars : List Char → String → String
  | [], out => out
  | '+' :: tail, out => decodeChars tail (out.push ' ')
  | '%' :: a :: b :: tail, out =>
    match hex a, hex b with
    | some high, some low => decodeChars tail (out.push (Char.ofNat (high * 16 + low)))
    | _, _ => decodeChars (a :: b :: tail) (out.push '%')
  | c :: tail, out => decodeChars tail (out.push c)

private def decodeComponent (value : String) : String := decodeChars value.toList ""

/-- `"?a=1&b=x%20y"` → `#[("a", "1"), ("b", "x y")]`, in order, with `+` and `%XX` decoded. -/
def parse (search : String) : Array (String × String) :=
  let body := match search.toList with | '?' :: rest => String.ofList rest | _ => search
  (body.splitOn "&").filter (· ≠ "") |>.toArray |>.map fun pair =>
    match pair.splitOn "=" with
    | [] => ("", "")
    | [key] => (decodeComponent key, "")
    | key :: rest => (decodeComponent key, decodeComponent (String.intercalate "=" rest))

/-- `application/x-www-form-urlencoded`, like `URLSearchParams`: `*-._` and alphanumerics stay, space is `+`. -/
private def encodeComponent (value : String) : String :=
  value.foldl (fun out c =>
    if c.isAlphanum || c == '*' || c == '-' || c == '.' || c == '_' then out.push c
    else if c == ' ' then out.push '+'
    else (String.toUTF8 (String.singleton c)).foldl (fun out byte => out ++ "%" ++ hexByte byte.toNat) out) ""
where hexByte (n : Nat) : String :=
  let digit (d : Nat) : Char := if d < 10 then Char.ofNat ('0'.toNat + d) else Char.ofNat ('A'.toNat + d - 10)
  String.singleton (digit (n / 16)) ++ String.singleton (digit (n % 16))

/-- `#[("a", "1")]` → `"a=1"` (no leading `?`); the empty array is `""`. -/
def encode (pairs : Array (String × String)) : String :=
  String.intercalate "&" (pairs.toList.map fun (key, value) => encodeComponent key ++ "=" ++ encodeComponent value)

end Query

/-- The current `pathname + search` and history actions. Concrete on purpose: one context serves every
application route type, so no per-application `TypeName` registration is needed. -/
structure RouteState where
  location : String
  /-- `pushState` with a same-origin path starting with `/`; a no-op when already there. -/
  navigate : String → Action Unit
  replace : String → Action Unit
  back : Action Unit
  deriving TypeName

/-- Browser: one history subscription (intrinsic, hook primitive `router`, arity 1). Native: the render
environment's in-memory `History`. -/
def useLocation (site : String := "") : Hook RouteState := ⟨fun env => do
  (Hook.mark "router" site).runRender env
  pure {
    location := ← env.history.current
    navigate := fun path => ⟨env.history.push path⟩
    replace := fun path => ⟨env.history.replace path⟩
    back := ⟨env.history.back⟩
  }⟩

/-- Applications define their own route type and a total codec. `parse` receives `pathname + search`
(`Route.split`, `Route.segments`, `Query.parse` help); `none` renders the `notFound` route. -/
structure RouteCodec (ρ : Type) where
  parse : String → Option ρ
  print : ρ → String

structure Router (ρ : Type) where
  current : ρ
  /-- The raw `pathname + search`, for "no screen for …" messages. -/
  location : String
  codec : RouteCodec ρ
  navigate : ρ → Action Unit
  replace : ρ → Action Unit
  back : Action Unit

def Router.href (router : Router ρ) (route : ρ) : String := router.codec.print route

def Router.ofState (codec : RouteCodec ρ) (notFound : ρ) (state : RouteState) : Router ρ := {
  current := (codec.parse state.location).getD notFound
  location := state.location
  codec
  navigate := fun route => state.navigate (codec.print route)
  replace := fun route => state.replace (codec.print route)
  back := state.back
}

/-- Owns a history subscription. Prefer one `routerProvider` per application and `useRoute` below it. -/
def useRouter (codec : RouteCodec ρ) (notFound : ρ) (site : String := "") : Hook (Router ρ) := do
  pure <| Router.ofState codec notFound (← useLocation site)

def routeState : Context RouteState := createContext "LeanReact.RouteState" {
  location := "/", navigate := fun _ => pure (), replace := fun _ => pure (), back := pure () }

structure RouterProps where
  children : Element

/-- Provides the browser location to descendants; consumers pick their route type with `useRoute`. -/
def routerProvider : Component RouterProps := Component.named "LeanReact.Router" <| component fun props => do
  let state ← useLocation "router"
  pure <| provide routeState state props.children

/-- The provided location decoded with the application's codec. -/
def useRoute (codec : RouteCodec ρ) (notFound : ρ) (site : String := "") : Hook (Router ρ) := do
  pure <| Router.ofState codec notFound (← useContext routeState site)

/-- An anchor with the route's `href` that navigates in place on an unmodified primary click; modified
clicks and non-anchor defaults stay with the browser. External URLs are ordinary `DOM.a` anchors. -/
def Router.link (router : Router ρ) (to : ρ) (props : DOM.Props := {}) (children : Array Element := #[]) : Element :=
  node "a" (props.attributes ++ #[.string "href" (router.href to), .navigate (router.navigate to)]) children

end LeanReact
