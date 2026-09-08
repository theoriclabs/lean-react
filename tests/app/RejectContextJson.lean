import LeanApp
def forge (json : Lean.Json) : Except String LeanApp.RequestContext :=
  Lean.fromJson? json
