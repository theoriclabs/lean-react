import PrivateNotes
open PrivateNotes

def broken (τ υ : Type) (snapshot : Snapshot) (p : Principal)
    (grant : ReadGrant τ snapshot.session p) :
    CertifiedNotes υ snapshot.session p := read grant {}
