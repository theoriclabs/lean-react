#!/usr/bin/env bash
# Parent-run loopback test: opens local sockets, never contacts an external host.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "--no-build" ]]; then bash examples/native/build-cached.sh; fi
binary_dir="$project_dir/examples/native/.lake/cached/bin"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tickets-http-check.XXXXXX")"
"$binary_dir/tickets_checks" --init "$test_dir/tickets.sqlite"
"$binary_dir/tickets_server" 0 "$test_dir/tickets.sqlite" > "$test_dir/server.stdout" 2> "$test_dir/server.log" &
server_pid=$!
finish() {
  if kill -0 "$server_pid" 2>/dev/null; then kill "$server_pid"; fi
  wait "$server_pid" 2>/dev/null || true
  echo "Retained HTTP fixture artifacts: $test_dir"
}
trap finish EXIT
port="$(lake env lean --run tests/Run.lean wait-ready "$test_dir/server.log")"
"$binary_dir/tickets_http_checks" "$port"
echo "PASS local Std.Http server + real LeanHttp requests"
