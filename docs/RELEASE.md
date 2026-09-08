# 0.2.0-rc.1 release preparation

This candidate introduces LeanApp's full-stack foundation and the [live Proof & Pour café](https://proof-and-pour-production.up.railway.app). It is experimental and has not been tagged, pushed, or published as a package. The owner selected MIT licensing and approved Railway hosting in Harsh Gupta's Projects. The published v0.1 frontend release remains unchanged. Package version fields stay at 0.1.0 until the release is cut; `0.2.0-rc.1` is the prepared candidate name.

## Candidate contents

The café demonstrates one Lean pricing/admissibility model running natively and in the browser, an authenticated recipe API, and private SQLite collections. Its React UI supports free previews, signup/login, persistent sessions, saved recipes, and deletion. Unavailable choices are disabled using candidate previews from the same Lean model, with accessible reasons. The server still rejects invalid or forged requests. Separate ordering tests exercise currency-indexed money, proof-bearing stock, and indexed order states.

Framework work includes typed application assembly, approved HTTP registries, browser/native transports, explicit SQLite transactions, and runtime-owned dispatch. This demo does not complete durable command receipts, effect delivery, or the full ordering application.

## Evidence

Validation: September 7–8, 2026. Local checks used macOS arm64, Lean 4.33.0 and Node 24.11.1. Railway built the café on Linux amd64 with Lean 4.33.0, Debian Bookworm, Node 24 and system OpenSSL 3.

| Check | Result |
| --- | --- |
| Café native executable | Ordinary Lake build passed against reviewed sibling sources. |
| Shared café rules | All 180 configurations match native Lean, generated JavaScript, and independent expected prices; 125 admissible. |
| Café HTTP | Signup, authoritative pricing, forged-price rejection, actor/tenant isolation, restart persistence, deletion and the 40-recipe bound pass. |
| Café browser | Both desktop/mobile tests pass, including bidirectional disabled choices, accessible explanations, keyboard skipping, signup/save/reload/logout/login/delete. |
| Existing framework/auth suites | Final `test:framework`, `test:framework:native` and `test:auth` reruns passed. Café/auth client checks passed all 24 tests. |
| Hosting process regressions | 650 rejected anonymous requests do not exhaust a global work quota; backend exit with an incomplete client upload respects the 20-second shutdown deadline. |
| Source snapshot | Allowlisted packaging with per-file SHA-256 manifest; no caches or databases. |
| Linux container / Railway | Native executable and crypto checks build/run; final deployment reached `SUCCESS` with `/health/ready` passing. |
| Public HTTPS checks | Real Chrome signup, Secure/HttpOnly/Strict cookie, no browser credential storage, CSRF/origin rejection, forged-price and invalid-cup rejection, account isolation, save/reload/login/delete, mobile controls and Why Lean pass. |
| Provider restart | Original sessions and isolated saved recipes survived a real Railway restart. |

Independent terminal review found shared-quota exhaustion by rejected anonymous traffic, premature shutdown-deadline cancellation, and a Docker port/default mismatch. Those code paths were corrected. The new process regressions passed; the image explicitly sets `PORT=8080`. The review does not certify the whole application.

The final deployed source snapshot is `.lake/releases/proof-and-pour-721TEq/`: 142 files, 11,123,593 bytes, independently rehashed against its manifest. `SOURCE-MANIFEST.json` has SHA-256 `0ba764ccc7c3a65e17ec02ac915851358d5da8d83878b929e7309c25550216d6`. It includes MIT and native dependency licenses; the container retains those notices. It is an allowlisted deployment snapshot, not a complete framework source distribution. Older snapshots remain retained.

## Hosted deployment

The [Railway service](https://railway.com/project/69daab8e-f6e4-4168-91b0-07b849c0ee25/service/1c57977a-da55-443d-832e-f11a9d7e37e6?environmentId=c6faf539-ae87-46e0-850e-eb08a889c65a) runs in `production` in Harsh Gupta's Projects. Final submitted deployment `c4c397e4-54ba-41a9-8cba-e2de3bd353e5` reached `SUCCESS`. It uses one `us-west2` replica, port 8080, `/health/ready` with a 120-second startup window, and up to three failure restarts. Volume `7d259bc3-b3da-462e-a434-841e3caecf89` is mounted at `/data`.

The provider reports image digest `sha256:cbd9bf0ac7b79e458aea5fc0d4acd3ac0ac0fe657bbf599586c7d5657b16e6ee`. The build log records the OCI image manifest digest `sha256:7258dd5106655af7bb858689a903f391e1da1992b6c3d8ae8e11a51eada0d394`. These identify different provider/build artifacts; neither is the source-manifest hash.

The initial build was replaced after volume/domain provisioning. Subsequent deployment `63b975ae-c144-49a3-8085-1c18073e3155` reached `SUCCESS` and passed the first public restart check. The final image adds runtime license notices and uses explicitly applied service settings. New Railway services ignore deprecated `railway.json`; the final snapshot omits it. CLI 5.45.5 also prioritizes piped stdin over setting flags, so the settings were applied as a reviewed JSON patch and read back successfully.

`scripts/check-cafe-hosted.mjs` is an opt-in, repeatable browser/API check. It creates disposable accounts, retains credentials only in memory, and deletes its own recipe after testing. Empty test accounts remain because the demo has no account-deletion API. No real customer data or orders were created.

Terminal receipts are `.terminal-subagents/cafe-ui-20260908T031645Z/receipt.json` (UI/client implementation) and `.terminal-subagents/leanapp-transactions-20260908T010515Z/receipt-5.json` (read-only review). The parent reviewed the changes, reran client tests and performed the native/browser qualification. Initial failed checks and older snapshots remain retained.

## Release cut

After this deployment, the owner approved the LeanApp monorepo identity. The root README and developer guides now use LeanApp as the framework name, and the private npm workspace is `leanapp-workspace`. LeanReact/LeanJS remain internal libraries; LeanDB/LeanHttp remain independent. Compatible Lake/import/wire names and the GitHub URL are unchanged. These documentation/metadata changes are newer than the hosted snapshot above and do not change its recorded hashes or imply another deployment.

The owner selected [MIT](../LICENSE). The root package and lockfile carry that license; native dependency notices are retained in snapshots and the runtime image.

Hosting and the public demo checks are complete. The README explains Lean's concrete advantages and links to the app, hosting instructions and known limits.

Before tagging, review the dirty worktree and staged release scope, align package versions with the chosen release, rerun checks, and verify the source manifest. No commit, tag, GitHub release, or npm publication has been made. Base-image/apt pinning and broad platform qualification remain incomplete.

## Known limits

This release is for evaluating domain-first application development. It is not end-to-end formally verified. LeanJS supports a subset of Lean; FFI, codecs, database behavior, browser execution and hosting remain tested trust boundaries.

The café saves recipes only; it does not implement paid orders. Authentication lacks password recovery/change, MFA and breached-password screening. Rate controls are local. SQLite uses one authoritative instance. Distributed command idempotency/outbox delivery, schema evolution/restore qualification, independent-consumer release testing and the Heroku gateway remain future work.
