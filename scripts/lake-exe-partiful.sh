#!/usr/bin/env bash
# DDD-LAPI-07: `lake exe partiful` in the staged app workspace (scripts/stage-partiful.py) builds
# the browser bundle as a dependency and serves the pages and the API on 127.0.0.1:8080 (the
# authored default), with no Python step and no LEANAPP_* variable. Uses the workspace's own
# `app.sqlite`.
# Usage: scripts/lake-exe-partiful.sh [APP_WORKSPACE]
set -euo pipefail
workspace=$(cd "${1:-$(dirname "$0")/../.lake/partiful-app}" && pwd)
log="$workspace/../ddd-m2-scratch/leanreact-lake-exe-partiful.log"
mkdir -p "$(dirname "$log")"
if lsof -nP -iTCP@127.0.0.1:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "127.0.0.1:8080 is already served; stop that server first" >&2
  exit 1
fi
cd "$workspace"
# A clean environment: no LEANAPP_* (or any other) variable; the build runs no Python step.
env -i HOME="$HOME" PATH="$PATH" LEAN_NUM_THREADS=2 \
  lake exe partiful > "$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; pkill -f "$workspace/.lake/build/bin/partiful$" 2>/dev/null || true' EXIT
for _ in $(seq 1 600); do
  grep -q '"event":"leanapi.ready"' "$log" && break
  kill -0 $pid 2>/dev/null || { cat "$log" >&2; exit 1; }
  sleep 0.5
done
grep -q '"port":8080' "$log"
echo "PASS: lake exe partiful is ready on port 8080"
page=$(curl -s -H 'Accept: text/html' http://127.0.0.1:8080/parties/new)
grep -q '<title>PartifulApp</title>' <<<"$page"
grep -q 'src="/assets/app.mjs"' <<<"$page"
echo "PASS: the pages are served"
test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/assets/app.mjs)" = 200
echo "PASS: the compiled bundle is served"
email="lake-exe-$(date +%s)-$$@example.com"
reply=$(curl -s -X POST http://127.0.0.1:8080/sign-up -H 'Accept: application/vnd.leanapp.token' \
  -d "{\"name\":\"Lake\",\"email\":\"$email\",\"password\":\"correct horse battery staple\"}")
grep -q '"token"' <<<"$reply"
test "$(curl -s -X POST http://127.0.0.1:8080/parties/1/rsvp)" = '{"error":"unauthorized"}'
echo "PASS: the API is served"
