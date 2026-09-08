import PrivateNotes
open PrivateNotes

-- The registered handler must produce a result, not a partially applied function.
def broken (snapshot : Snapshot) (p : Principal) (c : Criteria) :
    CertifiedNotes Unit snapshot.session p := read c
