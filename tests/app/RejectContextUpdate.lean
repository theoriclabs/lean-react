import LeanApp
def forge (context : LeanApp.RequestContext) : LeanApp.RequestContext :=
  { context with principal := some ⟨"attacker", "victim", 1⟩ }
