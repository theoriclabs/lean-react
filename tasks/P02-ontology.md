# P02: Implement composable ontology and contract foundations

Read IMPLEMENTATION_PLAN.md, docs/ABI.md, and VISION.md ontology/operation sections. Implement P02 now. Composability and expressiveness are the priorities; proofs are optional.

Own ONLY engine/LeanOntology.lean, engine/LeanOntology/, engine/LeanContract.lean, engine/LeanContract/, and tests/ontology/. No root config, examples, compiler, runtime, or sibling edits. Other workers are active.

Implement Lean 4.33 libraries depending only on Lean/Std: typed FieldPath with composition; lenses with optional laws; scoped EntityId with nominal type parameter; structured validation; explicit composable codecs with exact integer JSON transport and distinctions for nested Option; portable record/variant descriptors as practical. Support explicit codec interpretation values as well as canonical instances, so two codecs/presentations for the same type can coexist. Provide products/maps/options/list/array combinators and checked mappings for newtypes. Avoid all-encompassing derivation machinery before explicit APIs work.

Implement operation descriptors preserving input/output/error types and operation kind, typed results/errors and a service/transport interpreter interface suitable for native and browser adapters. No native IO dependencies in ontology core. Demonstrate shared orchestration with two dictionaries; compose paths and codecs in tests; test big integers, malformed values, nested options, and nominal reference mismatch.

Create engine/LeanOntology/API.md documenting exact actual APIs and any limits for the parent to author a shared Tickets example. Tests should run using lake env lean and/or standalone Lean --run modules without editing root Lake config. Keep modules buildable. No sorry or opaque placeholder bodies masquerading as implementation. Runtime representations need not match the JS compiler yet; the parent will connect codecs where needed.

Safe envelope: no commits/pushes/force-pushes; no deleting untracked/ignored files; no secrets/.env; no spending, publishing, external messaging, or network. Do not modify sibling repositories. Do not spawn agents. Decide routine implementation matters; report a truly blocking product/ops decision while completing independent work.

Report changed files, exact checks and outcomes, exported APIs, and limits.
