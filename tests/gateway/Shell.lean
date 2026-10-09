import LeanReact.Server
open LeanReact.Server LeanApi
instance : Inhabited Native.PageRoute := ⟨{ path := "", handler := fun _ => pure (Res.text "missing" 404) }⟩

def main (args : List String) : IO Unit := do
  let bundle : System.FilePath := args.head!
  let bootstrap := Lean.Json.mkObj [("actor", .null)]
  let custom : Shell := {
    title := some "<Shop & \"friends\">"
    style := some "body{max-width:none}"
    stylesheets := ["/assets/site.css"]
    navigation := some [("<Home & \"friends\">", "/?a=\"<&")]
    head := "<meta name=\"application\" content=\"shop\">" }
  let browser : Browser := {
    component := "shop"
    directory := bundle
    title := "Shop"
    pages := ["/", "/books", "/books/:book"] }
  let pages := publicPages browser bundle { custom with navigation := some [] }
  let page ← pages.head!.handler {}
  let defaultPage ← (publicPages browser bundle).head!.handler {}
  let css ← (stylesheetAssets bundle custom).head!.handler {}
  let invalid ← (stylesheetAssets bundle { stylesheets := ["/assets/../secret.css"] }).head!.handler {}
  IO.println (Lean.Json.mkObj [
    ("default", .str (String.fromUTF8! (html "Shop" ["/", "/books"] bootstrap {}).body)),
    ("defaultPage", .str (String.fromUTF8! defaultPage.body)),
    ("emptyStyle", .str (String.fromUTF8! (html "Shop" [] (.str "</script>") { style := some "" }).body)),
    ("custom", .str (String.fromUTF8! (html "Shop" [] bootstrap custom).body)),
    ("page", .str (String.fromUTF8! page.body)),
    ("css", .str (String.fromUTF8! css.body)),
    ("cssType", .str (css.header? "content-type" |>.getD "")),
    ("cache", .str (page.header? "cache-control" |>.getD "")),
    ("invalid", Lean.toJson invalid.status)]).compress
