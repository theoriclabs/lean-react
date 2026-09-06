# Experimental qualification

The first implementation was qualified on 2026-09-06 with Lean 4.33.0, Node 24.11.1, React 19.2.8, and macOS arm64. This records a working experimental subset, not completion of every API proposed in the [vision](../VISION.md). The [implemented scope](IMPLEMENTED.md) is the current support contract.

## Composition follow-up

The three concrete findings from the [frontend review](FRONTEND_READINESS.md) are resolved. `npm test` passed 57 JavaScript tests (8 compiler, 31 runtime, 18 generated integration) plus the Lean and TypeScript checks. New compiler checks cover monadic array iteration and library ownership/signature diagnostics. Generated tests cover nested collection validation, automatic context initialization through a record/factory, identical context objects across library imports, nested providers, live updates, and mismatched runtime interfaces.

The new collection and library Playwright tests pass in isolated Chrome. They exercise adding, editing, reordering, removing, and validating rows; retained row DOM/state; error paths after reorder; empty collections; and context updates between separately compiled libraries. The existing two Tickets browser tests also passed. One initial library test assertion could not locate a bare text node; its locator was corrected and both new browser tests passed on rerun. `npm run build` and the independent engine build passed.

The [composition guide](COMPOSABILITY.md) documents library identity, manifest-based imports, module-time initialization, and the current linking and recursion limits. The historical measurements and original qualification below predate these changes.

## Showcase website

The showcase adds a Lean-authored live counter, three selectable example flows, source excerpts loaded from the actual Lean files, and a shared-domain diagram. The website remains under `examples/web/`; its HTML/CSS shell and browser glue consume the Lean examples. It uses the existing toolchain and dependencies.

After the website changes, `npm test` passed all 57 JavaScript tests and the Lean/TypeScript checks. All six regular Playwright tests passed, including example navigation, the live counter, source inspection, copying setup commands, and all three examples at a 390-pixel viewport. Visual inspection caught a mobile grid sizing issue; it was fixed before the final captures. `scripts/screenshots.mjs` captures the real counter, a saved ticket edit, and a reordered collection with validation errors. The three README PNGs total about 644 KB. A full mobile capture is retained under ignored `.verification/showcase/`.

## Checks performed

| Command or check | Result and coverage |
| --- | --- |
| `npm test` | Passed: 52 JavaScript tests across compiler, runtime, and generated integration suites; native Lean reference/form/resource/query/cell checks; ontology tests and expected type rejections; static hook acceptance/rejection; TypeScript consumer checking. |
| `npm run test:compiler:integration` | Passed: the actual Tickets generator compiled against isolated rebuilt imports; two additional tests checked its hook metadata and declarations. Run after the compiler fixture suite. |
| `npm run build` | Passed: Lake build, generated domain/Tickets/interop modules, declarations/manifests, and browser bundle. A build was also exercised with fresh `examples/generated/` and `examples/dist/` directories; earlier output was retained under ignored `.verification/`. This used installed dependencies and Lean caches, not a fresh machine installation. |
| `npm run example:consumer` | Passed: the independent Node consumer calls the generated shared domain module without React. |
| `bash tests/native/check.sh` | Passed: optional native executables built; SQLite persistence, public identity, exact revisions, concurrent saves, native protocol, and process restart checks ran. |
| `bash tests/native/run-http.sh --no-build` | Passed: actual loopback Std.Http server and LeanHttp client round trips, including decoding typed conflict responses. |
| `npx playwright test` | Passed: two browser tests exercised the generated Lean UI, layout/footer/editor composition, validation, saves, independent counters, and mobile width. |
| `npx playwright test --config=playwright.native.config.mjs` | Passed: two browser tests exercised the same compiled workspace against SQLite, reload persistence, another writer's conflict, draft preservation, retry, incompatible contracts, and invalid inputs. |
| Local Lean import case audit | Passed across 69 source files. Lean modules use `examples/lean/Examples/`; browser/consumer files use `examples/`, avoiding a case-sensitive filesystem collision. |

Browser checks used an isolated browser with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. They used temporary local servers and fixtures. The native build reads the sibling `leandb_v2` and `leanhttp` checkouts and their existing dependencies; their source was not modified.

The compiler suite compares independently encoded native Lean and generated JavaScript results. It also checks output determinism across processes and diagnostics for unsupported native dependencies. Mounted tests execute generated component code rather than handwritten stand-ins. No browser page errors were observed in the application interaction tests.

## Integration review

Three terminal subagents implemented the compiler, neutral ontology/contracts, and React foundations, then took bounded integration tasks. Task descriptions are retained under `tasks/`; local worker receipts are under ignored `.terminal-subagents/`. The integrating agent reviewed their interfaces and reran the relevant checks.

Review exposed a local-service race: two saves within one React batch could both read the same committed state and accept the same revision. The local service now uses an immediate `Cell.modifyGet` transition; a regression check requires the first save to succeed and the second to conflict. The native service uses a mutex and database transaction independently.

Additional integration checks cover replacing a service while an earlier save is in flight and receiving an old list response after a newer save. A service-keyed mount isolates service ownership, and reconciliation preserves newer saved revisions. TypeScript declaration overload ordering was corrected so consumers infer the full callable signature. The embedded compiler runtime is a declared Lake input so changes invalidate its build artifact.

## Measurements

After the directory separation, `npm run benchmark` measured React `renderToString` for 1,000 compiled Lean stateful counters. After one warm-up, five samples had a median of **28.95 ms**, minimum **26.35 ms**, and maximum **42.15 ms**. The rendered HTML was 130,780 bytes.

| Artifact | Bytes | Gzip bytes |
| --- | ---: | ---: |
| `examples/generated/domain.mjs` | 93,216 | 12,668 |
| `examples/generated/tickets.mjs` | 234,329 | 29,503 |
| `examples/dist/app.js` | 1,375,154 | 224,502 |

These are development artifacts. The browser bundle includes React and is not minified; generated module sizes include reachable declarations and their runtime support. This is one local workload, with no handwritten React baseline, compiler wall-time study, production throughput claim, or hydration qualification. The benchmark writes its current measurements to `examples/generated/benchmark.json`.

## Remaining boundaries

The compiler is tied to the pinned Lean version and a documented portable subset. Automatic derivation/binding generation, a typed CSS API, Tailwind/shadcn setup, a shared query cache, SQL query lowering, routing, and React Server Components remain outside this delivery. The native HTTP adapter is a local integration fixture with explicit public operations. See [native limits and upstream proposals](NATIVE.md#limits-and-supported-upstream-proposals).

Test orchestration has been consolidated into `tests/Run.lean`. The compiler parity/determinism suite, isolated integration build, native protocol/restart checks, and HTTP readiness helper use Lean's standard APIs. The previous Python scripts have been removed. The main suite, separate compiler integration probe, native checks, and loopback HTTP checks were rerun with the Lean harness.

The engine and examples now occupy separate directories. `npm run build:engine` builds only engine targets, including reusable `LeanReact.Compiler` bindings. After relocation, the main suite, isolated compiler probe, independent consumer, native rebuild/persistence/HTTP checks, and a build from fresh example output directories passed. A source/link audit checked 71 Lean files, 38 JavaScript/TypeScript files, and 27 documents and found no engine-to-example imports.

Both browser suites passed after relocation (four tests). A live watch-mode check confirmed that changing an example source triggers one rebuild while generated modules and bundled assets are ignored, avoiding a rebuild loop now that outputs live beneath `examples/`.
