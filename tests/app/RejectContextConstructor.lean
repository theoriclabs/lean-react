import LeanApi.Publication
def forge : LeanApi.Publication.RequestContext :=
  ⟨some ⟨"attacker", "victim", 1⟩, "forged"⟩
