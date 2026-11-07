import LeanApi.Publication
def forge (json : Lean.Json) : Except String LeanApi.Publication.RequestContext :=
  Lean.fromJson? json
