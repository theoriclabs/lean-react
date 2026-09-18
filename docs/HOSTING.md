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

## Gateway module

The public process is [engine/gateway/index.mjs](../engine/gateway/index.mjs). `scripts/serve-cafe.mjs`, `scripts/serve-notes.mjs` and `scripts/auth-dev.mjs` are configurations of it; the deployment snapshot and both Dockerfiles ship the module next to the entry script. `createGateway(config)` spawns or attaches to the Lean process, waits for `/health/ready`, reads the public manifest, and only then listens. It resolves once listening and rejects after terminating the child when startup fails.

```js
await createGateway({
  name: 'Proof & Pour', port, origin,                  // exact public origin; development binds loopback and omits HSTS
  backend: { binary, port: backendPort, env: { LEANAPP_DB_PATH } },   // or { attach: { url: 'http://127.0.0.1:4178' } }
  assets: { dir: 'examples/dist-cafe', spa: false, files: [['/', 'index.html', 'text/html'], /* … */] },
  routes: { fromManifest: true, extra: ['/auth/*'], bodyBytes: { default: 8192, '/api/ops/submit': 262144 } },
  limits: { inFlight: 32, maxConnections: 64, upstreamTimeoutMs: 15000, requestTimeoutMs: 10000 },
  headers: { csp: "default-src 'self'; …" },           // defaults are the café's header set
  drainMs: 20000, log: 'json',                          // or 'silent'
  hooks: { onProxied(req, reply) {} },                  // reply: { status, headers, body } after each proxied exchange
  websocket: { path: '/ws', backendPort: wsPort, maxSockets: 4096, maxPerCookie: 8, handshakeTimeoutMs: 5000, idleTimeoutMs: 90000 },
  events: { path: '/stream', maxStreams: 2000, maxStreamsPerCookie: 8, maxTopicsPerTicket: 4, pingMs: 20000, queueBytes: 65536, mustDeliver: ['ops'] },
});
```

`events` tunes the SSE fallback described in [Live events](ARCHITECTURE.md#live-events); it activates only when the manifest declares `metadata.publish` or `issuesStreamTicket` operations (`events: false` disables it). Streams need `Accept: text/event-stream`, a session cookie and a ticket bound to that cookie; they receive `retry:`, `hello {topics, lastEventId}`, published events with monotonic `id:` lines, `ping` every `pingMs` and `bye` on drain. Each stream buffers about 16 KiB in Node plus `queueBytes` in the hub; when that is full, droppable events go oldest first and an event named in `mustDeliver` closes the stream instead. Raise `limits.maxConnections` to cover `maxStreams` plus ordinary traffic. Counters: `leanapp_gateway_streams`, `stream_topics`, `stream_tickets`, `streams_total`, `stream_publishes_total{event}`, `stream_deliveries_total`, `stream_dropped_total`, `stream_closed_total{reason}`, `stream_rejected_total{reason}`. `node tests/gateway/load-events.mjs` is an opt-in load check (2,000 idle streams plus a publish rate) that reads the gateway's event-loop lag from `/internal/metrics`.

With `websocket` configured, `Connection: Upgrade` requests on `websocket.path` are checked at the edge — exact `Origin` (403), a `leanapp_session`/`__Host-leanapp_session` cookie present (401; Lean validates the value), `Sec-WebSocket-Version: 13` (426), `Sec-WebSocket-Protocol` containing `leanapp.v1` (400), no duplicated guarded headers (400), `maxSockets` (503) and `maxPerCookie` (429, counted by a hash of the cookie value that is never logged) — then piped byte for byte to Lean's loopback WebSocket listener. Only `origin`, `cookie`, `sec-websocket-*` and the generated `x-request-id` are forwarded; `x-forwarded-for` is not. The gateway parses no frames and holds no session state: a refused or unanswered backend yields 502 or 504, an idle pipe is cut after `idleTimeoutMs`, and a half-close from either side ends both. Without `websocket` every upgrade request is answered 404. On drain the listener closes first, HTTP exchanges finish and Lean receives SIGTERM while pipes stay open so it can close sessions with 1001; whatever remains is destroyed at `drainMs`. Upgrades are logged as lines with `kind: "upgrade"` and counted in `leanapp_gateway_ws_sockets`, `leanapp_gateway_ws_upgrades_total{outcome}` and `leanapp_gateway_ws_bytes_total{direction}`.

The spawned child receives `LEANAPP_ORIGIN` and `LEANAPP_BACKEND_PORT` from the gateway plus `backend.env`. The allowlist is a set of literal paths: every `operations[].http.path` in `GET /api/manifest`, the manifest path, `/health/ready`, and `routes.extra` entries, which are literal paths or `prefix/*`. Manifest paths must satisfy the same literal-path rule as `HttpBinding.validate`; a violation or an unreachable manifest refuses to start. Operations without `http.path` (older binaries) produce one warning and are covered by `routes.extra`. Requests to anything else, or with methods other than GET/POST, are answered 404 before reaching Lean. Per-route `http.maxBodyBytes` from the manifest overrides `routes.bodyBytes`.

Every proxied request keeps the existing gates: duplicate forwarded headers are rejected, `X-LeanApp-Request: 1` is required except for readiness, POSTs need the exact `Origin` and a JSON content type, only `origin, cookie, content-type, x-csrf-token, x-leanapp-request, accept` travel upstream and only `set-cookie, content-type, retry-after` travel back. The in-flight cap answers 429 with `Retry-After`; the body cap answers 413. `npm run test:gateway` exercises each gate against a stub backend, including drain timing and backend crash propagation.

## Operations

With `log: 'json'` the gateway writes one JSON line per request to stdout, versioned with `v: 1`:

```json
{"v":1,"ts":"2026-09-18T07:40:35.153Z","requestId":"3kq0Zt4a9XyBv1Qe","method":"POST","path":"/api/recipes/save","status":200,"upstreamStatus":200,"durations":{"total":12.4,"upstream":11.9},"bytes":{"in":181,"out":412},"streamEventsPublished":0}
```

`path` is logged without its query; cookies, bodies, usernames and tokens never appear, so every field is safe to ship to a log service. `requestId` is generated by the gateway for each request (16 URL-safe characters; client-supplied ids are ignored), forwarded upstream as `X-Request-Id` and returned to the client in the same header so users can quote it. `upstreamStatus` and `durations.upstream` are `null` when the gateway answered without reaching Lean. Startup and lifecycle events use the same format with an `event` field (`listening`, `backend_exit`, `manifest_unbound_operations`).

`GET /internal/metrics` returns the gateway's own counters in Prometheus text format to loopback peers only; every other `/internal/*` request, and any `/internal/*` request from a non-loopback address, is answered 404 and is never proxied. Families: `leanapp_gateway_in_flight`, `leanapp_gateway_requests_total{status}`, `leanapp_gateway_rejected_total{reason}` (`forbidden`, `throttled`, `duplicate_header`, `body_too_large`, `not_allowed`, `upstream_error`, `internal`, `draining`), `leanapp_gateway_upstream_total{status}`, `leanapp_gateway_upstream_ms_total`, and `leanapp_gateway_event_loop_lag_ms{quantile}` covering the interval since the previous scrape. Counters reset on restart. Scrape from a sidecar in the same network namespace, or run `curl -s http://127.0.0.1:$PORT/internal/metrics` inside the container. A rising `rejected_total{reason="throttled"}` rate means the in-flight cap is saturating before Lean does; `upstream_ms_total / upstream_total` rising with a flat request rate means Lean itself is slowing down.

## Operational boundaries

The public process bounds body size and active upstream work. Native auth separately limits admitted password work. These controls are process-local; they do not replace provider-level abuse protection. Use disposable demo passwords and avoid sensitive recipe names. Password reset and account recovery are unavailable.

On SIGTERM, the public process stops admission and drains active HTTP exchanges before terminating Lean. A 20-second deadline forces remaining connections closed. SQLite transactions provide crash recovery; this is not the complete framework migration/drain/outbox lifecycle. Back up the volume before schema changes and qualify restoration before depending on it. Schema mismatch refuses ordinary runtime admission.

The café passed a Linux amd64 provider build and public browser/API smoke checks, including a real Railway restart. This does not qualify other Linux architectures or Heroku's durable-data arrangement.

The opt-in public check creates two disposable accounts and removes its own test recipe:

```sh
node scripts/check-cafe-hosted.mjs https://YOUR_CAFE_DOMAIN --allow-mutations --pause-for-restart
```

Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` if using an installed Chrome. When the check pauses, restart only the intended service, verify its new process is ready, then press Enter. Cookies and generated passwords remain in memory; empty test accounts remain afterward because the demo has no account-deletion API.
