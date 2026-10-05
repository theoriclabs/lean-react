import tests.domain.PostPart1
open LeanApp.Domain
-- The time must come from the server's clock; `Now` has no request codec.
def hostAt (me : SignedIn) (now : Now) : Op HostError Unit := pure ()
derive_operation hostAt
