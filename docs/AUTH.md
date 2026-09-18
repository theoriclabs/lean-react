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

Signup creates an account and signs it in immediately. By default each account starts with a private tenant; the [tenant policy](#tenant-policy) below can share one workspace or require an invite. There is one active session per account: a successful login increments its generation and revokes previous sessions. Sessions expire after 24 hours by default, without sliding renewal. The native service allows a configured lifetime of at most seven days.

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

## HTTP and browser integration

| Route | Behavior |
| --- | --- |
| `POST /auth/signup` | Exact JSON fields `username` and `password`; under the invite policy also `invite`. Creates account and session. |
| `POST /auth/login` | Same input; verifies credentials and replaces prior sessions. |
| `GET /auth/session` | Returns the current public user and CSRF token. |
| `POST /auth/logout` | Requires session and CSRF token; revokes the session and clears the cookie. |
| `POST /api/whoami` | Demo typed query; returns only the current account's username. |
| `GET /health/ready` | Public runtime readiness. |

Auth requests use `X-LeanApp-Request: 1`. POST requests require JSON and the exact configured `Origin`; protected operations and logout also require `X-CSRF-Token`. Signup/login responses contain public user data and CSRF, never the session bearer token. No CORS allowance is emitted.

The production cookie is `__Host-leanapp_session`, with `Secure`, `HttpOnly`, `SameSite=Strict`, and `Path=/`. Production configuration requires an HTTPS origin behind trusted TLS ingress. The explicitly enabled loopback development mode uses a separate cookie name without `Secure`. Host and forwarded headers never choose the trusted origin or principal. Responses disable caching, and authentication errors omit internal diagnostics.

`engine/LeanApp/AuthClient.mjs` provides `signup`, `login`, `logout`, `restore`, authenticated requests, subscriptions, and a demo Contract call helper. It sends cookies with same-origin requests and keeps CSRF only in memory. Auth transitions serialize cookie-changing requests and invalidate client ownership immediately; late responses cannot update a later session. Neither passwords nor bearer tokens are written to browser storage. The demo call helper is not a replacement for the generic client's full typed domain-error transport.

Native applications import `LeanAppNative.Auth.Http`, include `Auth.tables` in their LeanDB base, create `Auth.Service` from the owned runtime, and create an `Auth.Host` from approved application metadata and a connection-bound factory. Current session expiry, generation, enabled state, and tenant are checked under the same owned callback that constructs and dispatches the application. Expensive password work happens outside the database lock, with account state rechecked before issuing a session.

The account, session and invite tables are private. Do not export generic CRUD for them. Native access changes revoke sessions; tenant changes, account disabling and invite issuance have no public HTTP endpoint. Adding the invite table changes the LeanDB schema fingerprint: an existing instance needs one additive `migrate apply` (a `CREATE TABLE`, no rebuild or drop) before the runtime admits requests again. Trusted native handlers must not retain the callback connection or recursively enter the runtime. Domain transactions remain explicit handler responsibility.

## Verification and limits

```sh
npm run test:auth
npm run test:auth:browser
```

For offline native checks, set `LEANAPP_LEANSQLITE_SOURCE` to a SQLite source checkout. If Playwright's bundled browser is absent, set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to an installed Chrome executable. Build the auth demo before running browser tests independently.

Native checks cover hashing, token handling, signup/login failures, session rotation and expiry, access revocation, CSRF, trusted origin, cookies, runtime admission, password-work contention, and the three tenant policies (shared workspace with owner-scoped reads; missing, forged, used and expired invites; single use inside the signup transaction). Real HTTP checks exercise SQLite persistence across restart, account isolation, and the `fixed`/`invite` policies through `LEANAPP_TENANT_POLICY`. Browser checks exercise signup through logout/relogin and invalid-input handling. Mocked transport checks cover stale-response ownership.

There is no password reset/change flow, email verification, MFA, or breached-password screening yet. Public signup needs ingress-level abuse controls. OpenSSL error handling has been reviewed but RNG/allocation/provider failures have not been fault-injected. Qualification covers macOS arm64 and the café's Linux amd64 container on Railway, including TLS ingress and a real restart with preserved sessions. Complete application shutdown, broad platform distribution and Heroku remain unqualified. The separate Tickets example still uses its named local fixture policy.
