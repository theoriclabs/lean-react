import Lean

namespace LeanAppNative.Sha256

/-! Streaming SHA-256 (FIPS 180-4 §§4.1.2, 4.2.2, 5, 6.2), carried over from the LeanDB 0.3
development tree (MIT, Theoric Labs) when the native adapter moved to the published LeanDB 0.4.0,
which no longer ships it. Used for correlation hashes in request logs only: credential storage
and token digests use the OpenSSL bindings in `Auth.Crypto`. -/

private def initial : Array UInt32 :=
  #[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

private def constants : Array UInt32 :=
  #[0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

private def rotr (x n : UInt32) : UInt32 := (x >>> n) ||| (x <<< (32 - n))

private def compress (state : Array UInt32) (bytes : ByteArray) (offset : Nat) : Array UInt32 := Id.run do
  let mut w : Array UInt32 := #[]
  for i in [:16] do
    let p := offset + i * 4
    w := w.push ((bytes[p]!.toUInt32 <<< 24) ||| (bytes[p+1]!.toUInt32 <<< 16) |||
      (bytes[p+2]!.toUInt32 <<< 8) ||| bytes[p+3]!.toUInt32)
  for i in [16:64] do
    let x := w[i-15]!
    let y := w[i-2]!
    let s0 := rotr x 7 ^^^ rotr x 18 ^^^ (x >>> 3)
    let s1 := rotr y 17 ^^^ rotr y 19 ^^^ (y >>> 10)
    w := w.push (w[i-16]! + s0 + w[i-7]! + s1)
  let mut a := state[0]!
  let mut b := state[1]!
  let mut c := state[2]!
  let mut d := state[3]!
  let mut e := state[4]!
  let mut f := state[5]!
  let mut g := state[6]!
  let mut h := state[7]!
  for i in [:64] do
    let s1 := rotr e 6 ^^^ rotr e 11 ^^^ rotr e 25
    let ch := (e &&& f) ^^^ ((~~~e) &&& g)
    let t1 := h + s1 + ch + constants[i]! + w[i]!
    let s0 := rotr a 2 ^^^ rotr a 13 ^^^ rotr a 22
    let maj := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)
    let t2 := s0 + maj
    h := g
    g := f
    f := e
    e := d + t1
    d := c
    c := b
    b := a
    a := t1 + t2
  return (state.zip #[a,b,c,d,e,f,g,h]).map fun (x,y) => x + y

structure State where
  private words : Array UInt32 := initial
  private pending : ByteArray := .empty
  private size : UInt64 := 0

def State.update (s : State) (bytes : ByteArray) : State := Id.run do
  let data := s.pending ++ bytes
  let mut words := s.words
  for i in [:data.size / 64] do
    words := compress words data (i * 64)
  let remaining := data.extract (data.size / 64 * 64) data.size
  return { words := words, pending := remaining, size := s.size + bytes.size.toUInt64 }

def State.finish (s : State) : String := Id.run do
  let mut tail := s.pending.push 0x80
  while tail.size % 64 != 56 do
    tail := tail.push 0
  let bits := s.size * 8
  for i in [:8] do
    tail := tail.push ((bits >>> ((7-i)*8).toUInt64).toUInt8)
  let mut words := s.words
  for i in [:tail.size / 64] do
    words := compress words tail (i*64)
  let hex := "0123456789abcdef".toList.toArray
  let mut chars := #[]
  for w in words do
    for i in [:8] do
      chars := chars.push hex[((w >>> ((7-i)*4).toUInt32) &&& 15).toNat]!
  return String.ofList chars.toList

def bytes (data : ByteArray) : String := (State.update {} data).finish
def string (text : String) : String := bytes text.toUTF8

end LeanAppNative.Sha256
