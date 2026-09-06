import LeanReact

namespace Examples.Libraries
open LeanReact

structure Formatter where
  heading : String
  format : String → String
  deriving TypeName

def formatter : Context Formatter :=
  createContext "Formatter" { heading := "Default", format := id }

-- Equal display names must not merge independent context declarations.
def otherFormatter : Context Formatter :=
  createContext "Formatter" { heading := "Other", format := id }

end Examples.Libraries
