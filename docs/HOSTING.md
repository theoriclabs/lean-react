# Hosting Proof & Pour

For the separately hosted proof-carrying authorization app, see [Private Notes hosting](PRIVATE_NOTES.md#host-your-own) and its [deployment receipt](../deploy/notes/README.md). It uses a different service, volume and local port pair; never share the café's database with it.

The café uses one public Node process and one loopback-only Lean process in a container. SQLite stores accounts, sessions, and private recipes on a persistent volume. Public HTTPS terminates at the hosting provider. Only approved auth/recipe routes are proxied; database administration is not exposed.

[Open Proof & Pour](https://proof-and-pour-production.up.railway.app). It runs in Harsh Gupta's Projects, project/service `proof-and-pour`, environment `production`, with one replica and a `/data` volume. [Release evidence](RELEASE.md) records the exact deployment and source digest.

## Build context

The native package currently uses reviewed sibling sources. This command creates a new self-contained source snapshot with a SHA-256 manifest of every included file:

```sh
npm run package:cafe
```

It prints a directory under `.lake/releases/` containing the application, selected LeanDB/LeanHttp/SQLite sources and their licenses, and a Dockerfile. The runtime image retains the application's MIT license and native dependency notices. Caches, repository metadata, credentials, and databases are excluded. Each invocation gets a new directory; older snapshots remain untouched.

Overrides are `LEANAPP_LEANDB_SOURCE`, `LEANAPP_LEANHTTP_SOURCE`, and `LEANAPP_LEANSQLITE_SOURCE`. The default SQLite source is `../leandb_v2/.lake/packages/leansqlite`. The container compiles native dependencies from source and verifies the exact Lean 4.33.0 Linux archive's published SHA-256 digest. Node's Debian base image and apt repositories are not yet immutable release pins.

Build from the printed directory:

```sh
docker build -t proof-and-pour:0.2.0-rc.1 .
```

For a server behind your own HTTPS reverse proxy, attach a named volume and publish only the proxy-facing loopback port:

```sh
docker run --rm -p 127.0.0.1:8080:8080 -v proof-and-pour-data:/data \
  -e LEANAPP_ORIGIN=https://cafe.example.com \
  -e LEANAPP_DB_PATH=/data/cafe.sqlite proof-and-pour:0.2.0-rc.1
```

Replace the example origin with your actual HTTPS origin and configure its proxy separately. For local browser development, use `npm run dev:cafe`. Development mode intentionally binds to loopback and omits Secure cookies; never use it on a public service.

## Railway

Deploy the generated context in the intended workspace. A new service needs a public domain and a volume mounted at `/data` before it can start successfully. [Railway volumes](https://docs.railway.com/volumes) persist service data and are mounted at runtime, not during the build.

```sh
railway up -y --name proof-and-pour --workspace WORKSPACE_ID --detach --no-gitignore
railway volume --project PROJECT_ID --environment ENVIRONMENT_ID --service SERVICE_ID add --mount-path /data --json
railway domain --project PROJECT_ID --environment ENVIRONMENT_ID --service SERVICE_ID --port 8080 --json
```

Run from the generated context, or pass explicit project/environment/service IDs. `--no-gitignore` is appropriate only for this inspected snapshot, not the development checkout. Observe `SUCCESS` for the submitted deployment and check its HTTPS `/health/ready` endpoint before reporting it live.

New Railway services no longer accept legacy `railway.json` configuration. This bundle uses an ordinary Dockerfile and explicit service settings; it does not contain a legacy config file. Railway's [configuration documentation](https://docs.railway.com/config-as-code) explains the transition to Infrastructure as Code for projects that want source-managed infrastructure.

Set the service's builder to `DOCKERFILE`, Dockerfile path to `Dockerfile`, healthcheck path to `/health/ready`, healthcheck timeout to 120 seconds, and restart policy to `ON_FAILURE` with three retries. Keep one replica. On CLI 5.45.5, non-interactive `environment edit` reads stdin before command-line setting flags, so supply the reviewed patch as JSON:

```sh
printf '%s' '{"services":{"SERVICE_ID":{"build":{"builder":"DOCKERFILE","dockerfilePath":"Dockerfile"},"deploy":{"healthcheckPath":"/health/ready","healthcheckTimeout":120,"restartPolicyType":"ON_FAILURE","restartPolicyMaxRetries":3,"numReplicas":1}}}}' | \
  railway environment edit --project PROJECT_ID --environment ENVIRONMENT_ID --json
```

Replace all three identifiers with the returned IDs, inspect existing configuration first, and read it back afterward. The initial build may finish before the domain/volume are ready; submit a scoped deployment after configuration and track that deployment's result.

The application uses `RAILWAY_PUBLIC_DOMAIN` for its exact HTTPS origin and `RAILWAY_VOLUME_MOUNT_PATH` for its persistent database location. Alternatively set `LEANAPP_ORIGIN` and `LEANAPP_DB_PATH`. Incoming Host and forwarded headers never choose these values. Keep one replica attached to the SQLite volume. Do not store the database on an ephemeral container filesystem.

The image listens on `PORT` (8080) and starts Lean on `LEANAPP_BACKEND_PORT` (4181). Health checks use `/health/ready`. A missing configured origin or persistent path fails startup. Production cookies are Secure/HttpOnly/SameSite=Strict; no CORS allowance is emitted.

## Operations

The Lean process writes one JSON line per request to stderr (`LEANAPP_LOG_FILE=<path>` appends to a file instead; `LEANAPP_LOG=off` silences it). The format is versioned with `v: 1`:

| Field | Meaning |
| --- | --- |
| `ts` | Unix time in milliseconds. |
| `requestId` | The client's `X-Request-Id` when it is 1–64 URL-safe characters, else a generated `r<ms>-<n>`. It also reaches `RequestContext.requestId`. |
| `method`, `path`, `status` | Literal request path (no decoding) and the response status. |
| `operation` | `{namespace, name, version}` of the dispatched Contract operation, or `null` for auth, health and unmatched routes. |
| `outcome` | `success`, `domainError`, `decode`, `protocol`, `unauthenticated`, `forbidden`, `incompatible`, `failed` or `unavailable`. |
| `principalHash` | SHA-256 of the actor id truncated to 16 hex characters, or `null`. Never the actor, username or session. |
| `durations` | Milliseconds: `total` for the whole exchange and the disjoint phases `auth` (session resolution, or KDF work on credential routes), `queueWait` (waiting for the writer), `db` (connection held for application assembly) and `handler` (policy and handler). `auth + queueWait + db + handler ≤ total`; the writer was held for about `db + handler` plus `auth` on authenticated operations. |
| `bodyBytes`, `replyBytes` | Sizes only. |
| `error` | Only when an exception was caught: `{class, code}` with the `IO.Error` class and the sanitized code the client saw. `message` is added only with `LEANAPP_LOG_ERRORS=verbose`, which is for development. |

Every field is safe to ship to a log service: bodies, tokens, cookies, CSRF values, usernames and SQL never appear, which `npm run test:auth` and `npm run test:framework:native` check by parsing the lines and searching them for the credentials they used. A caught exception outside a request (dispatch-only hosts) is an `{"event":"error","component",…}` line with the same class/code rule. To check the café yourself, run its browser suite with logging on and grep the file for the suite's password, username and cookie name:

```sh
LEANAPP_LOG_FILE=/tmp/cafe-log.jsonl npm run build:cafe && LEANAPP_LOG_FILE=/tmp/cafe-log.jsonl npm run test:cafe:browser
grep -c 'afternoon-oat-test-passphrase\|browser_barista\|leanapp_session=' /tmp/cafe-log.jsonl   # 0
```

Counters live in process memory (reset on restart) and are exposed in Prometheus text format at `GET /internal/metrics`, answered only to loopback peers and never proxied by the public process (it returns 404 there). Scrape it from a sidecar or the same container: `curl http://127.0.0.1:4181/internal/metrics`. It exposes `leanapp_requests_total{operation,outcome}`, the histograms `leanapp_request_duration_ms`, `leanapp_request_db_ms` (connection-held time) and `leanapp_request_queue_wait_ms`, the counters `leanapp_auth_throttles_total`, `leanapp_rate_limited_total`, `leanapp_request_body_bytes_total` and `leanapp_reply_bytes_total`, and the live gauges `leanapp_writer_queue_depth`, `leanapp_writer_active`, `leanapp_writer_completed_total` and the `leanapp_auth_session_cache_*` counters. Later subsystems register gauges by name through `Metrics.setGauge`.

Saturation heuristics: a rising `queueWait` p95 with flat `db` means the single writer is saturated (add the session cache, shorten handlers or move reads off the writer); `leanapp_writer_queue_depth` approaching the runtime's `maxPending` (128) means `503 application.unavailable` is imminent; a growing `outcome="unavailable"` share confirms it. `auth` dominating `total` on credential routes is expected KDF cost (about 0.1–0.3 s); `leanapp_auth_throttles_total` climbing means the credential gate is refusing work. `leanapp_rate_limited_total` counts declared per-principal limits firing; anonymous traffic is the public process's concern.

## Operational boundaries

The public process bounds body size and active upstream work. The Lean process bounds simultaneous connections (`LEANAPP_BACKEND_MAX_CONNECTIONS`, default 64), applies each operation's declared body cap before buffering, and enforces declared per-principal rate limits with `429` and `Retry-After`. Native auth separately limits admitted password work. These controls are process-local; they do not replace provider-level abuse protection. Use disposable demo passwords and avoid sensitive recipe names. Password reset and account recovery are unavailable.

On SIGTERM, the public process stops admission and drains active HTTP exchanges before terminating Lean. A 20-second deadline forces remaining connections closed. SQLite transactions provide crash recovery; this is not the complete framework migration/drain/outbox lifecycle. Back up the volume before schema changes and qualify restoration before depending on it. Schema mismatch refuses ordinary runtime admission.

The café passed a Linux amd64 provider build and public browser/API smoke checks, including a real Railway restart. This does not qualify other Linux architectures or Heroku's durable-data arrangement.

The opt-in public check creates two disposable accounts and removes its own test recipe:

```sh
node scripts/check-cafe-hosted.mjs https://YOUR_CAFE_DOMAIN --allow-mutations --pause-for-restart
```

Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` if using an installed Chrome. When the check pauses, restart only the intended service, verify its new process is ready, then press Enter. Cookies and generated passwords remain in memory; empty test accounts remain afterward because the demo has no account-deletion API.
