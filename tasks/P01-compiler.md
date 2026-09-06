# P01: Implement the portable Lean compiler

Read IMPLEMENTATION_PLAN.md and docs/ABI.md, then carry out P01. Read VISION.md's compiler and composition sections. This is implementation, not just research.

Own ONLY engine/LeanJS.lean, engine/LeanJS/, and tests/compiler/. Other agents own ontology and React modules; the parent owns root config and examples. Do not modify their files. Write engine/LeanJS/ABI.md early to document the concrete value representation, arity, intrinsic convention, and compiler entry point.

Build a real Lean 4.33.0 to JavaScript ESM compiler for a useful explicitly supported subset. You may choose elaborated Lean.Expr, compiler LCNF, or IR after inspecting installed sources. Need literals, let/functions/applications, higher-order closures, generic code/typeclass dictionaries, records/variants and matches, Nat exact arithmetic, strings, and useful pure recursion. Support native-reference functions through an extensible intrinsic map so LeanReact need not be imported by LeanJS. Provide callable code generation plus a Lean command or executable entry point that can be used without editing root config. Test actual generated code with Node and show parity with native Lean for representative functions. Unsupported native operations must fail with a helpful dependency path, not silently emit undefined.

Prioritize real useful composition over expanding primitive coverage indiscriminately. Do not use static fixture translation or hand-authored JS outputs in place of compiling declarations. No placeholder implementation for claimed supported constructs. Expose limits honestly. You can request root config/dependencies by writing an interface note in engine/LeanJS/ABI.md.

Environment: Lean pinned in lean-toolchain; use lake env lean for file checks. Parent will run lake build after modules land. Node 24 is installed. No network is necessary. Installed Lean compiler source is at /Users/harshwork/.elan/toolchains/leanprover--lean4---v4.33.0/src/lean/Lean/Compiler.

Safe envelope: no commits/pushes/force-pushes; no deleting untracked/ignored files; no secrets/.env; no spending, publishing, or external messaging; no network. Do not modify sibling repositories. Do not spawn more agents. Make routine implementation decisions within this task; if a new product/ops decision is truly required, report it while completing independent work.

When finished report files changed, exact checks run and outcomes, compiler entry point, unsupported features, and integration notes.
