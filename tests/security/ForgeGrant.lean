import PrivateNotes
open PrivateNotes

def broken (s : SessionFacts) (p : Principal) (h : SessionValid s p) : ReadGrant Unit s p :=
  ReadGrant.mk h
