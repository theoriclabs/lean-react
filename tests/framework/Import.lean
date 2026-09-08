import LeanApp

def emptyApplication : Ontology.Validation (LeanApp.Application Id) :=
  LeanApp.Application.create "empty" []

def main : IO Unit :=
  match emptyApplication with
  | .ok app =>
      if app.manifest.isEmpty then IO.println "PASS: portable empty application"
      else throw <| IO.userError "empty application exposed an operation"
  | .error errors => throw <| IO.userError (reprStr errors)
