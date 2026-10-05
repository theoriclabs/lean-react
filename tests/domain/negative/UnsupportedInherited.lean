import LeanApp.Domain
open LeanApp.Domain
structure Base where
  title : Title
  deriving Domain
structure Child extends Base where
  extra : Text
  deriving Domain
