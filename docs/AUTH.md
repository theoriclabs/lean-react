# Username/password authentication

LeanApp now has signup, login, logout, and persistent server sessions. Lean checks credentials and current account access; React displays the forms and calls the HTTP adapter. No external identity-provider account is required.

The standalone auth demo below is loopback-only. The same adapter also runs in the [hosted café](https://proof-and-pour-production.up.railway.app), where HTTPS cookies, account isolation and session persistence passed public browser/API checks. It remains experimental.

## Run the demo

Use the repository's Lean toolchain, installed npm dependencies, the sibling LeanDB/LeanHttp checkouts, and OpenSSL 3 development headers/library. The native package uses Homebrew's `/opt/homebrew/opt/openssl@3` on macOS or system paths on Linux. Pass `-Kopenssl=/absolute/prefix` to Lake for another installation. Linux qualification currently covers the café's Debian amd64 container and crypto checks; see [release evidence](RELEASE.md).

In the first terminal, from the repository root:

```sh
cd adapters/native
lake build leanapp_auth_demo
.lake/build/bin/leanapp_auth_demo 4176 .lake/auth-demo.sqlite http://127.0.0.1:4175
```

In another terminal, from the repository root:

```sh
LEANAPP_AUTH_API=http://127.0.0.1:4176 npm run dev:auth
```

Open `http://127.0.0.1:4175`, choose **Sign up**, and create an account. The protected “Check who I am” request resolves the signed-in account from SQLite. Reloading the page or restarting the backend preserves an unexpired session. Restart the frontend process after editing its source; this small development server does not provide hot reload.

The database path is persistent. Use a new path for an isolated demo. SQLite normally comes from its pinned Lake dependency; offline builds can pass `-Kleansqlite=/absolute/path/to/leansqlite` before `build`.

## Account and session rules

Usernames contain 3–32 ASCII letters, digits, underscores, or hyphens. They are case-insensitive and stored lowercase. Passwords contain 15–128 Unicode code points and at most 1,024 UTF-8 bytes. Passwords are not trimmed or normalized, and have no composition rule.

Signup creates an account and signs it in immediately. By default each account starts with a private tenant; the [tenant policy](#tenant-policy) below can share one workspace or require an invite. Sessions expire after 24 hours by default, without sliding renewal. The native service allows a configured lifetime of at most seven days.

By default (`maxSessions := 1`) there is one active session per account: a successful login increments the account's generation and revokes previous sessions. With `Service.Config.maxSessions` above one (`LEANAPP_MAX_SESSIONS` in the executables), a login adds a session, evicts only the oldest sessions beyond the cap by creation time, and leaves the generation alone; the generation stays the revoke-everything switch, bumped by a password change, sign-out-everywhere and `setAccess`. Each session records when it was created, when it was last seen (refreshed at most once per five minutes) and an optional client-supplied label (printable ASCII, at most 64 characters; disable storage with `sessionLabel := false`). Session listings use an opaque id derived from the session's own secrets, never the stored bearer digest. A password change verifies the current password under the same gate and throttles as login, stores the new hash, bumps the generation and re-issues the caller's session so that device stays signed in while every other one is revoked. Existing instances migrate additively: the three new session columns are nullable, so `migrate apply` only adds columns.

Password hashes use OpenSSL scrypt with `N=131072`, `r=8`, `p=1`, a random 16-byte salt, and a 32-byte derived key. These parameters match an [OWASP-listed scrypt configuration](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html). Session and CSRF tokens each use 32 random bytes from OpenSSL. SQLite stores only the SHA-256 digest of the session bearer token. Password hashes remain private native data.

One password operation is admitted at a time per auth service. Process-local limits allow 60 admitted credential attempts per minute globally and 10 per canonical username. Concurrent requests rejected by the password-work gate do not consume those quotas. These are bounded local controls, not distributed or per-IP abuse protection. Use one auth service per application runtime.

## Tenant policy

`Auth.Service.new runtime (config := { tenantPolicy := … })` chooses how signup assigns `Principal.tenant`; every scoped read still checks it. The application executables read `LEANAPP_TENANT_POLICY` (`private`, `fixed:<name>`, or `invite`); the library takes only the typed value.

| Policy | Signup | Threat model |
| --- | --- | --- |
| `.privatePerAccount` (default) | The tenant is the new actor id: every account is alone. | Isolation is the product (Private Notes). Nothing is shared until a trusted native `setAccess` moves an account. |
| `.fixed name` | Every account joins `name` (nonempty, at most 64 characters, validated when the service starts). | Anyone who can sign up can be shared with. Use it only behind ingress abuse controls (or a closed signup page), and keep owner checks (`owner ∧ tenant`) in application reads so a shared tenant does not mean shared rows. |
| `.invite` | `POST /auth/signup` needs a third exact field `invite`: a token issued by the trusted native call `Service.createInvite tenant ttl`. The account joins the invite's tenant. | Only invite holders can join, and only once: the token digest is checked and marked used inside the signup transaction, before the username-availability check, so a missing, used, expired or forged token returns `403 auth.invite_required` and reveals no usernames. Invites are bearer tokens; deliver them out of band and keep lifetimes short. |

`setAccess` remains the administrative override under every policy and still revokes the account's sessions. There is no public endpoint for issuing invites in this release.

## Session cache

`Service.Config.sessionCacheTtlMs` (`LEANAPP_SESSION_CACHE_TTL_MS` in the executables; default 0 = off, 30 s recommended) keeps resolved sessions in process memory, keyed by the token digest and guarded by the service's small mutex, never the database queue. A hit skips only the two point reads of the authentication step; the application callback still runs under `withConnection`, and hits still check CSRF and session expiry. Because exactly one Lean process serves an instance, every event that changes session validity happens here and invalidates immediately: logout, targeted revocation, sign-out-everywhere, password change, `setAccess` and eviction by the session cap. The TTL bounds staleness only for defence in depth and for `lastSeenAt`, which a hit does not refresh. `sessionCacheMax` (default 10,000 entries) clears the cache when full. `Service.cacheStats` reports hits, misses, invalidations and size. `npm run test:auth` ends with a load check of 10,000 authenticated calls with the cache off and on and prints the wall-time reduction (about 45 % on a laptop, where the authentication reads and their query-log writes were roughly half of the writer's time per call).

## HTTP and browser integration

| Route | Behavior |
| --- | --- |
| `POST /auth/signup` | Exact JSON fields `username` and `password`, optionally `label`; under the invite policy also `invite`. Creates account and session. |
| `POST /auth/login` | Same input; verifies credentials, then replaces the session (`maxSessions = 1`) or adds one within the cap. |
| `GET /auth/session` | Returns the current public user and CSRF token. |
| `POST /auth/logout` | Requires session and CSRF token; revokes the session and clears the cookie. |
| `POST /auth/sessions` | Requires session and CSRF token; lists the caller's live sessions as `{id, label, createdAt, lastSeenAt, current}`, newest first. |
| `POST /auth/sessions/revoke` | Exact field `id`; revokes that session of the caller (`404 auth.session_not_found` otherwise). Revoking the current one clears the cookie like logout. |
| `POST /auth/logout-all` | Bumps the generation, deletes every session of the caller and clears the cookie. |
| `POST /auth/password` | Exact fields `currentPassword` and `newPassword`; same throttles as login. Returns the re-issued session like login and sets a new cookie. |
| `POST /api/whoami` | Demo typed query; returns only the current account's username. |
| `GET /health/ready` | Public runtime readiness. |

Auth requests use `X-LeanApp-Request: 1`. POST requests require JSON and the exact configured `Origin`; protected operations and logout also require `X-CSRF-Token`. Signup/login responses contain public user data and CSRF, never the session bearer token. No CORS allowance is emitted.

The production cookie is `__Host-leanapp_session`, with `Secure`, `HttpOnly`, `SameSite=Strict`, and `Path=/`. Production configuration requires an HTTPS origin behind trusted TLS ingress. The explicitly enabled loopback development mode uses a separate cookie name without `Secure`. Host and forwarded headers never choose the trusted origin or principal. Responses disable caching, and authentication errors omit internal diagnostics.

`engine/LeanApp/AuthClient.mjs` provides `signup`, `login`, `logout`, `restore`, `sessions`, `revokeSession`, `logoutAll`, `changePassword`, authenticated requests, subscriptions, and a demo Contract call helper. Signup and login send a coarse device label (`deviceLabel()`, for example "Chrome on macOS"), overridable per call. It sends cookies with same-origin requests and keeps CSRF only in memory. Auth transitions serialize cookie-changing requests and invalidate client ownership immediately; late responses cannot update a later session. Neither passwords nor bearer tokens are written to browser storage. The demo call helper is not a replacement for the generic client's full typed domain-error transport.

Each binding may declare `HttpBinding.maxBodyBytes`, which replaces `ServerConfig.maxBodyBytes` for that literal path and is applied before the body is buffered (a 300 KiB body to a 256 KiB path is refused at the byte limit, never parsed), and `HttpBinding.rateLimit` (`perPrincipalPerMinute`, `burst`), which the host enforces per `(actor, operation)` with a process-local token bucket: excess requests get `429` with a `Retry-After` header and the protocol code `request.rate_limited`. Anonymous requests are not subject to per-principal limits; the gateway's global caps remain their protection. `ServerConfig.maxConnections` (default 64, `LEANAPP_BACKEND_MAX_CONNECTIONS` in the executables) bounds simultaneous connections on the Lean listener.

Native applications import `LeanAppNative.Auth.Http`, include `Auth.tables` in their LeanDB base, create `Auth.Service` from the owned runtime, and create an `Auth.Host` from approved application metadata and a connection-bound factory. Current session expiry, generation, enabled state, and tenant are checked under the same owned callback that constructs and dispatches the application. Expensive password work happens outside the database lock, with account state rechecked before issuing a session.

The account, session and invite tables are private. Do not export generic CRUD for them. Native access changes revoke sessions; tenant changes, account disabling and invite issuance have no public HTTP endpoint. Adding the invite table changes the LeanDB schema fingerprint: an existing instance needs one additive `migrate apply` (a `CREATE TABLE`, no rebuild or drop) before the runtime admits requests again. Trusted native handlers must not retain the callback connection or recursively enter the runtime. Domain transactions remain explicit handler responsibility.

## Verification and limits

```sh
npm run test:auth
npm run test:auth:browser
```

For offline native checks, set `LEANAPP_LEANSQLITE_SOURCE` to a SQLite source checkout. If Playwright's bundled browser is absent, set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to an installed Chrome executable. Build the auth demo before running browser tests independently.

Native checks cover hashing, token handling, signup/login failures, session rotation and expiry, access revocation, CSRF, trusted origin, cookies, runtime admission, password-work contention, the three tenant policies (shared workspace with owner-scoped reads; missing, forged, used and expired invites; single use inside the signup transaction), concurrent sessions (eviction of the oldest beyond the cap, opaque ids, labels, `lastSeenAt` cadence, targeted and self revocation, password change keeping only the caller, throttled wrong current passwords, sign-out-everywhere) and an additive migration of a pre-LA-02 session table. Real HTTP checks exercise SQLite persistence across restart, account isolation, the `fixed`/`invite` policies through `LEANAPP_TENANT_POLICY`, and the multi-session routes with `LEANAPP_MAX_SESSIONS=3`. Browser checks sign in on two devices, revoke one from the other and confirm only the revoked side is signed out. Browser checks exercise signup through logout/relogin and invalid-input handling. Mocked transport checks cover stale-response ownership.

There is no password reset, email verification, MFA, or breached-password screening yet; password change requires the current password on a live session. Public signup needs ingress-level abuse controls. OpenSSL error handling has been reviewed but RNG/allocation/provider failures have not been fault-injected. Qualification covers macOS arm64 and the café's Linux amd64 container on Railway, including TLS ingress and a real restart with preserved sessions. Complete application shutdown, broad platform distribution and Heroku remain unqualified. The separate Tickets example still uses its named local fixture policy.
