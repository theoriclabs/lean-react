import Ordering
open Ordering
def rejected (c : AdmissibleConfiguration) : AdmissibleConfiguration :=
  { c with value := { temperature := .iced, size := .small } }
