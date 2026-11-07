import LeanReact.Program.Html

/-! # Element combinators: `button [cls "primary", onClick .start] [text "Start"]` -/

namespace LeanReact.Program

def text (value : String) : Html Msg := .text value
/-- Nothing (`Html.none`). -/
def nothing : Html Msg := .none
def when (condition : Bool) (view : Html Msg) : Html Msg := if condition then view else .none
/-- One keyed child per item, in a `tag` (default `div`); keys must be distinct. -/
def each (items : List α) (key : α → String) (row : α → Html Msg) (attrs : List (Attr Msg) := [])
    (tag : String := "div") : Html Msg :=
  .node tag attrs (items.map fun item => .keyed (key item) (row item))
def lazy (key : String) (view : Unit → Html Msg) : Html Msg := .lazy key view

def el (tag : String) (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node tag attrs children

def div (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "div" attrs children
def span (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "span" attrs children
def p (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "p" attrs children
def section_ (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "section" attrs children
def article (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "article" attrs children
def header (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "header" attrs children
def footer (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "footer" attrs children
def main_ (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "main" attrs children
def nav (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "nav" attrs children
def aside (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "aside" attrs children
def h1 (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "h1" attrs children
def h2 (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "h2" attrs children
def h3 (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "h3" attrs children
def h4 (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "h4" attrs children
def h5 (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "h5" attrs children
def h6 (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "h6" attrs children
def ul (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "ul" attrs children
def ol (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "ol" attrs children
def li (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "li" attrs children
def a (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "a" attrs children
def strong (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "strong" attrs children
def em (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "em" attrs children
def code (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "code" attrs children
def pre (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "pre" attrs children
def button (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "button" attrs children
def form (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "form" attrs children
def label (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "label" attrs children
def select (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "select" attrs children
def option (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "option" attrs children
def table (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "table" attrs children
def thead (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "thead" attrs children
def tbody (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "tbody" attrs children
def tr (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "tr" attrs children
def th (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "th" attrs children
def td (attrs : List (Attr Msg)) (children : List (Html Msg)) : Html Msg := .node "td" attrs children
def input (attrs : List (Attr Msg)) : Html Msg := .node "input" attrs []
def textarea (attrs : List (Attr Msg)) : Html Msg := .node "textarea" attrs []

end LeanReact.Program
