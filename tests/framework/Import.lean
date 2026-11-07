import LeanApi.Publication

def emptyApplication : Ontology.Validation (LeanApi.Publication.Application Id) :=
  LeanApi.Publication.Application.create "empty" []

def main : IO Unit :=
  match emptyApplication with
  | .ok app =>
      if app.manifest.isEmpty then IO.println "PASS: portable empty application"
      else throw <| IO.userError "empty application exposed an operation"
  | .error errors => throw <| IO.userError (reprStr errors)
