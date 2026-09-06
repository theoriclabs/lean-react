import LeanReact
open LeanReact

example (parser : DraftParser Raw Value) (raw : Raw) : Hook (Form Raw Value) := useForm parser raw
example (field : FieldBinding α) (lens : Ontology.Lens α β) : FieldBinding β := field.focus lens
example (loader : ResourceRequest → Action (Except Error Value)) : Hook (Resource Value Error) :=
  useResource (Key.string "generic") loader

#check_failure useForm (DraftParser.identity : DraftParser Nat Nat) "wrong raw type"
#check_failure (show Editor String from component fun (_ : FieldBinding Nat) => pure empty)
#check_failure (show FieldBinding Nat → FieldBinding String from fun field => field.focus (Ontology.Lens.id : Ontology.Lens String String))
#check_failure (show Form String Nat → Action (Ontology.Validation Unit) from fun form => form.submit (fun (_ : String) => pure ()))
#check_failure useResource (Key.string "request") (fun (_ : String) => (pure (.ok 1) : Action (Except String Nat)))
