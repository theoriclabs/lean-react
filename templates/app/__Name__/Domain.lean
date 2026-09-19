namespace {{Name}}

/-- A note title: nonempty and at most 120 scalars. `parse` is the only way to make one, in the
browser (compiled by LeanJS) and on the server alike, so the rule lives in exactly one place. -/
structure Title where
  private mk ::
  value : String
  deriving Repr, BEq, DecidableEq

def Title.parse (raw : String) : Except String Title :=
  if raw.isEmpty then .error "title.empty"
  else if raw.length > 120 then .error "title.too_long"
  else .ok ⟨raw⟩

end {{Name}}
