import LeanReact

namespace Examples.Routing
open LeanReact

/-- The application's own route type. `notFound` carries no payload; the router keeps the raw location. -/
inductive Route where
  | home
  | ticket (id : Nat)
  | about
  | notFound
  deriving Repr, BEq

/-- This page lives under `/router/`, so the codec owns that base segment in both directions. -/
def codec : RouteCodec Route := {
  parse := fun location =>
    match (Route.segments (Route.split location).1).toList with
    | ["router"] => some .home
    | ["router", "about"] => some .about
    | ["router", "tickets", id] => (Route.nat? id).map Route.ticket
    | _ => none
  print := fun
    | .home => "/router/"
    | .about => "/router/about"
    | .ticket id => s!"/router/tickets/{id}"
    | .notFound => "/router/not-found"
}

def tickets : Array (Nat × String) := #[(1, "Fix the login redirect"), (2, "Write the release notes"), (3, "Plan the roadmap")]

def ticketTitle (id : Nat) : Option String :=
  (tickets.find? (·.1 == id)).map (·.2)

def Screen : Component Unit := Component.named "RoutedScreen" <| component fun _ => do
  let router ← useRoute codec .notFound "route"
  let navigation := DOM.nav { ariaLabel := some "Screens" } #[
    router.link .home { data := #[("testid", "link-home")] } #[text "Tickets"],
    router.link .about { data := #[("testid", "link-about")] } #[text "About"],
    -- An external URL is an ordinary anchor: the browser handles it.
    DOM.a { href := "https://github.com/theoriclabs/lean-react", rel := some "noreferrer" } #[text "GitHub"]]
  let body := match router.current with
    | .home => DOM.section {} #[
        DOM.h2 {} #[text "Tickets"],
        DOM.ul {} (tickets.map fun (id, title) =>
          DOM.li {} #[router.link (.ticket id) { data := #[("testid", s!"link-ticket-{id}")] } #[text title]])]
    | .ticket id => DOM.section {} #[
        DOM.h2 {} #[text s!"Ticket {id}"],
        DOM.p {} #[text ((ticketTitle id).getD "This ticket does not exist.")],
        DOM.div { className := some "toolbar" } #[
          DOM.button { onPress := some router.back } #[text "Back"],
          DOM.button { onPress := some (router.navigate .home) } #[text "All tickets"],
          DOM.button { onPress := some (router.replace .about) } #[text "Replace with About"]]]
    | .about => DOM.section {} #[
        DOM.h2 {} #[text "About"],
        DOM.p {} #[text "Deep links, back and forward, and in-place link clicks through one typed route."]]
    | .notFound => DOM.section { role := some "alert" } #[
        DOM.h2 {} #[text "Not found"],
        DOM.p {} #[text s!"No screen for {router.location}."],
        router.link .home {} #[text "Go to the tickets"]]
  pure <| DOM.div { className := some "panel routed" } #[navigation, body,
    DOM.p { className := some "note", data := #[("testid", "location")] } #[text router.location]]

def App : Component Unit := Component.named "RoutedApp" <| component fun _ =>
  pure <| element routerProvider { children := element Screen () }

end Examples.Routing
