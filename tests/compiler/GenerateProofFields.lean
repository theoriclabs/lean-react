import LeanJS
import tests.compiler.ProofFields
open Lean
#lean_js "tests/compiler/proof-fields.mjs" [ProofFields.score, ProofFields.identityCast, ProofFields.Count.make, ProofFields.Text.make, ProofFields.Indent.ofNat?, ProofFields.Delta.ofOps, ProofFields.Normal.check, ProofFields.Delta.normalize, ProofFields.Chain.make]
