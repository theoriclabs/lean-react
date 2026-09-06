# P03: Implement composable LeanReact APIs and React runtime

Read IMPLEMENTATION_PLAN.md, docs/ABI.md, and VISION.md component/composition sections. Implement P03. This is a library implementation, not a static website.

Own ONLY engine/LeanReact.lean, engine/LeanReact/, engine/runtime/, and tests/runtime/. No root config, examples, ontology, compiler, or sibling edits. Other workers are active.

Build the Lean 4.33 source API around Component Props, Hook alpha, Action alpha, component/element/text/fragment/keyedEach, typed DOM helpers and event callbacks, useState, custom hooks, providers/context and managed effects as feasible. Composition through callbacks and slots must be first-class. Simple components must not need event enums or explicit effect rows. Start with function-based DOM construction; syntax can follow. Make all claimed APIs buildable Lean with meaningful reference semantics, not axioms/sorry.

Build the JavaScript/TypeScript React runtime bridge in engine/runtime/. Parent will provide React/react-dom dependencies and a DOM test environment. Use native ESM .mjs where this avoids unnecessary tooling. A runtime intrinsic adapter must be explicit; compiler worker chooses ABI and will write engine/LeanJS/ABI.md. Do NOT guess the backend ABI. Document required intrinsic declarations and bridge signatures in engine/runtime/INTRINSICS.md for integration. The JS runtime should work and be testable independently of the compiler, but document that compiler integration is parent's remaining task.

Implement managed actions that execute only at event/effect time, React component identity and keyed children, functional state updates, callbacks/render props, hook composition, typed context and lifecycle cleanup. Define a practical hook-placement validation interface or diagnostic plan; don't claim a static checker exists if it doesn't. Runtime tests should verify actual React behavior where dependencies are available, or add them to run once parent installs dependencies. Document any needed packages rather than editing package.json or installing packages yourself. Provide engine/LeanReact/API.md with complete example code in actual implemented APIs.

Safe envelope: no commits/pushes/force-pushes; no deleting untracked/ignored files; no secrets/.env; no spending, publishing, external messaging, or network. Do not modify sibling repositories. Do not spawn agents. Decide routine implementation matters; report truly blocking product/ops decisions while completing independent work.

Report changed files, exact tests/outcomes, APIs, required intrinsic adapter work, and limitations.
