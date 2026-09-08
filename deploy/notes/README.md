# Private Notes deployment

The [application guide](../../docs/PRIVATE_NOTES.md) covers the demonstration, proof boundary, local checks and source packaging. This record is separate from the café's release evidence.

## Source and target

- Service: `private-notes` (`2d5fe8a3-9b54-4c7c-ac4b-0ef415218c55`).
- Workspace: Harsh Gupta's Projects (`6d86328a-32d7-4925-b889-1911185e39ca`).
- Project: `69daab8e-f6e4-4168-91b0-07b849c0ee25`; production environment `c6faf539-ae87-46e0-850e-eb08a889c65a`.
- HTTPS address: [Private Notes](https://private-notes-production.up.railway.app).
- Separate volume: `d51fed49-2113-461d-8421-866f1c549ce5`, mounted at `/data`; database `/data/notes.sqlite`.
- One replica in `us-west2`, port 8080, native loopback listener 4191, readiness `/health/ready`, 120-second health-check timeout, on-failure restart limit 3.
- Source snapshot: `.lake/releases/private-notes-jUepGE`, 151 allowlisted source files, 11,135,241 bytes.
- `SOURCE-MANIFEST.json` SHA-256: `8291b939395243b98b46a2f96998fa4896da52408803a341c288e269373b31be`.

The snapshot contains no account database, cache or credentials. MIT and native dependency notices are retained in the runtime image. Source changes were not committed, pushed or tagged. The existing Proof & Pour deployment was not changed.

## Qualification

Local macOS checks passed: nine theorem dependency audits; eight rejected candidate patches with an accepted control; native owner/tenant isolation, lease retirement, callback rollback and committed revocation; real HTTP scope/query/session/restart checks; fresh-Chromium desktop/mobile workflows. The existing auth regression profile also passed after the additive transaction-aware host change.

The café was rebuilt locally against that shared auth change and all three café regression suites passed, including 180-configuration parity, persistence/isolation and gateway shutdown. An initial sandboxed test invocation could not open loopback sockets (`EPERM`); the permitted socket-enabled rerun passed. This local rebuild did not redeploy the café.

On September 8, 2026, deployment `34c73377-a703-4813-a1fd-1ff5e0784a48` reached Railway `SUCCESS`. The deployment metadata records image digest `sha256:0c328f8412c9fcc1a835c079207d93726ec08f875e4fe7e448afd4e5f2deca79`. The Linux build passed all proof/rejection checks, production OpenSSL crypto checks, and ten native notes assertions before its readiness check succeeded.

The public Chromium run passed signup, real note bodies, search/count, direct foreign/archive/missing probes, JSON export, session restoration, logout/login, Secure/HttpOnly/Strict cookies, empty browser credential storage, agent-evidence rendering and desktop/mobile layout. Screenshots are retained locally under `.lake/security/notes-workspace.png` and `notes-agent.png`.

The public API check passed HTTPS/readiness/security headers, strict authority-field rejection, CSRF/origin checks, two-account isolation, equivalent foreign/missing responses, literal search/count/export and session rotation/logout. It verified that the live model/policy bytes match both the build receipt and the local checked sources. The Linux evidence was generated at `2026-09-08T08:27:37.821Z`.

The service was then restarted through Railway, without rebuilding. Railway returned the same deployment ID, reported one running replica and `SUCCESS`, and public readiness returned 200. The original cookies, readable notes and synthetic fixture IDs survived. The completed API receipt is `.lake/security/hosted-check.json`, timestamp `2026-09-08T08:34:51.086Z`. Two disposable API-test accounts remain with their sessions logged out; the browser check leaves one additional synthetic account. No credentials were recorded.

Proof & Pour still reports `SUCCESS` on its original deployment `c4c397e4-54ba-41a9-8cba-e2de3bd353e5` and its original independent volume. No café deployment, domain or configuration was changed.

To repeat the public checks (they intentionally create disposable accounts):

```sh
npm run test:notes:browser -- https://private-notes-production.up.railway.app --allow-mutations
npm run test:notes:hosted -- https://private-notes-production.up.railway.app --allow-mutations
```

Add `--pause-for-restart` to the API command to keep cookies in memory while an operator restarts **only this service**. Verify provider success and public readiness before pressing Enter. Tests and documentation added after packaging do not change the recorded deployed source manifest; app/model/native source matches that snapshot.
