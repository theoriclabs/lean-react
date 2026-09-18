import LeanReact

open LeanReact

private def assertTrue (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

inductive Route where
  | home
  | ticket (id : Nat)
  | notFound
  deriving Repr, BEq

def codec : RouteCodec Route := {
  parse := fun location =>
    match (Route.segments (Route.split location).1).toList with
    | [] => some .home
    | ["tickets", id] => (Route.nat? id).map Route.ticket
    | _ => none
  print := fun
    | .home => "/"
    | .ticket id => s!"/tickets/{id}"
    | .notFound => "/missing"
}

def Consumer : Component Unit := component fun _ => do
  let router ← useRoute codec .notFound "route"
  pure <| router.link (.ticket 9) { className := some "next" } #[text s!"at {router.location}"]

def main : IO Unit := do
  let history ← History.create "/tickets/2?tab=notes"
  let first ← Reference.runHook (useRouter codec .notFound "route") (history := some history)
  assertTrue (first.value.current == .ticket 2) "deep link decoded"
  assertTrue (first.value.location == "/tickets/2?tab=notes") "raw location retained"
  assertTrue (first.trace == #[⟨"router", "route"⟩]) "router hook trace"
  Reference.runAction (first.value.navigate .home)
  assertTrue ((← history.current) == "/") "navigate pushed"
  let second ← Reference.runHook (useRouter codec .notFound "route") (history := some history)
  assertTrue (second.value.current == .home) "route follows history"
  Reference.runAction second.value.back
  assertTrue ((← history.current) == "/tickets/2?tab=notes") "back restored the entry"
  Reference.runAction second.value.back
  assertTrue ((← history.current) == "/tickets/2?tab=notes") "back at the first entry is a no-op"
  Reference.runAction (second.value.replace (.ticket 5))
  assertTrue ((← history.current) == "/tickets/5") "replace rewrote the entry"
  assertTrue ((← history.entries.get) == #["/tickets/5", "/"]) "forward entry kept by replace"
  history.forward
  assertTrue ((← history.current) == "/") "forward"
  history.back
  Reference.runAction (second.value.navigate (.ticket 7))
  assertTrue ((← history.entries.get) == #["/tickets/5", "/tickets/7"]) "push dropped forward entries"

  let missing ← Reference.runHook (useRouter codec .notFound "route") (history := some (← History.create "/nowhere"))
  assertTrue (missing.value.current == .notFound && missing.value.location == "/nowhere") "unknown path is notFound"

  let tree ← Reference.render (element routerProvider { children := element Consumer () }) (history := some history)
  assertTrue (Reference.RenderedTree.textContent tree.value == "at /tickets/7") "provider supplied the location"
  let some anchor := Reference.RenderedTree.byTag? tree.value "a" | throw <| IO.userError "missing link"
  assertTrue (Reference.attribute? anchor "href" == some "/tickets/9") "link href"
  assertTrue (Reference.attribute? anchor "className" == some "next") "link props"
  Reference.dispatchNavigate anchor
  assertTrue ((← history.current) == "/tickets/9") "link navigated in memory"
  let fallback ← Reference.render (element Consumer ())
  assertTrue (Reference.RenderedTree.textContent fallback.value == "at /") "context default location"

  assertTrue (Query.parse "?a=1&b=x%20y+z&c&d=e=f" == #[("a", "1"), ("b", "x y z"), ("c", ""), ("d", "e=f")]) "Query.parse"
  assertTrue (Query.parse "" == #[]) "Query.parse empty"
  assertTrue (Query.encode #[("a b", "1&2"), ("ü", "~*")] == "a+b=1%262&%C3%BC=%7E*") "Query.encode"
  assertTrue (Route.split "/tickets/42?x=1#frag" == ("/tickets/42", "x=1")) "Route.split"
  assertTrue (Route.segments "/tickets/42/?x=1" == #["tickets", "42"]) "Route.segments"
  assertTrue (Route.nat? "42" == some 42 && Route.nat? "4a" == none && Route.nat? "" == none) "Route.nat?"
  assertTrue (Route.join #["tickets", "42"] == "/tickets/42" && Route.join #[] == "/") "Route.join"
  IO.println "LeanReact router reference checks passed (codec, navigate/replace/back, provider, link, URL helpers)."
