import LeanApp
def forge : LeanApp.RequestContext :=
  ⟨some ⟨"attacker", "victim", 1⟩, "forged"⟩
