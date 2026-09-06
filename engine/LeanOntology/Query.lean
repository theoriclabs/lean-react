/- A small, host-neutral query description with an ordered reference interpreter. -/
namespace Ontology

/-- Query stages are values. Functions remain local; this is not a wire or SQL AST. -/
inductive Query (Row : Type) : Type → Type 1 where
  | source : Query Row Row
  | select (input : Query Row α) (project : α → β) : Query Row β
  | restrict (input : Query Row α) (keep : α → Bool) : Query Row α
  | limit (input : Query Row α) (count : Nat) : Query Row α
  | combine (left right : Query Row α) : Query Row α
  | product (left : Query Row α) (right : Query Row β) : Query Row (α × β)

namespace Query

def map (input : Query Row α) (project : α → β) : Query Row β := .select input project
def filter (input : Query Row α) (keep : α → Bool) : Query Row α := .restrict input keep
def take (input : Query Row α) (count : Nat) : Query Row α := .limit input count
def append (left right : Query Row α) : Query Row α := .combine left right
def cross (left : Query Row α) (right : Query Row β) : Query Row (α × β) := .product left right

private def keepValues (keep : α → Bool) : List α → List α
  | [] => []
  | value :: rest => if keep value then value :: keepValues keep rest else keepValues keep rest

private def first : Nat → List α → List α
  | 0, _ => []
  | _ + 1, [] => []
  | n + 1, value :: rest => value :: first n rest

private def pairs (left : List α) (right : List β) : List (α × β) :=
  match left with
  | [] => []
  | head :: rest => right.map (head, ·) ++ pairs rest right

/-- Evaluate stages in written order. No limit/filter reordering or implicit pushdown. -/
def run : Query Row α → List Row → List α
  | .source, rows => rows
  | .select input project, rows => (run input rows).map project
  | .restrict input keep, rows => keepValues keep (run input rows)
  | .limit input count, rows => first count (run input rows)
  | .combine left right, rows => run left rows ++ run right rows
  | .product left right, rows => pairs (run left rows) (run right rows)

def stages : Query Row α → List String
  | .source => ["source"]
  | .select input _ => stages input ++ ["map (Lean)"]
  | .restrict input _ => stages input ++ ["filter (Lean)"]
  | .limit input count => stages input ++ ["take " ++ toString count]
  | .combine left right => ["append"] ++ stages left ++ stages right
  | .product left right => ["cross"] ++ stages left ++ stages right

end Query
end Ontology
