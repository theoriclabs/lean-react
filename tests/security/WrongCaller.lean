import PrivateNotes
open PrivateNotes

def broken (snapshot : Snapshot) (alice bob : Principal)
    (grant : ReadGrant Unit snapshot.session alice) :
    CertifiedNotes Unit snapshot.session bob := read grant {}
