import LeanApi.Publication
def forge (context : LeanApi.Publication.RequestContext) : LeanApi.Publication.RequestContext :=
  { context with principal := some ⟨"attacker", "victim", 1⟩ }
