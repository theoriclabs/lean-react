#!/usr/bin/env bash
set -euo pipefail

native_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$native_dir/../.." && pwd)"
adapter_dir="$project_dir/adapters/native"
# The pinned dependencies live in the adapter's package directory (LA-12); the Tickets package
# shares it through `packagesDir`. Build them once with: (cd adapters/native && lake build LeanDb LeanHttp)
packages_dir="$adapter_dir/.lake/packages"
db_dir="$packages_dir/leandb"
http_dir="$packages_dir/leanhttp"
sqlite_dir="$packages_dir/leansqlite"
build_dir="$native_dir/.lake/cached"
mkdir -p "$build_dir/lib/lean" "$build_dir/ir" "$build_dir/bin"
export LEAN_PATH="$build_dir/lib/lean:$db_dir/.lake/build/lib/lean:$sqlite_dir/.lake/build/lib/lean:$http_dir/.lake/build/lib/lean"

# No Lake update/build here: the pinned dependencies' generated files remain read-only.
for artifact in "$db_dir/.lake/build/lib/lean/LeanDb/Db.olean" \
  "$http_dir/.lake/build/lib/lean/LeanHttp.olean" \
  "$sqlite_dir/.lake/build/lib/libleansqlite.a" "$http_dir/.lake/build/lib/libleanhttp.a"; do
  if ! test -f "$artifact"; then
    echo "Missing cached dependency: $artifact" >&2
    echo "Dependency build: (cd adapters/native && lake build LeanDb LeanHttp)" >&2
    exit 2
  fi
done

compile_module() {
  local module="$1" source="$2" source_root="$3"
  local package="tickets_native"
  if [[ "$source_root" != "$native_dir" ]]; then package="leanreact"; fi
  if [[ "$source_root" == "$adapter_dir" ]]; then package="leanapp_native"; fi
  mkdir -p "$(dirname "$build_dir/lib/lean/$module.olean")" "$(dirname "$build_dir/ir/$module.c")"
  # Preserve module identity independently of the engine/example source roots.
  printf '{"name":"%s","package":"%s","isModule":false,"importArts":{},"dynlibs":[],"plugins":[],"options":{}}\n' \
    "${module//\//.}" "$package" > "$build_dir/ir/$module.setup.json"
  lean --setup "$build_dir/ir/$module.setup.json" -R "$source_root" \
    -o "$build_dir/lib/lean/$module.olean" -c "$build_dir/ir/$module.c" "$source"
  leanc -c -O2 -o "$build_dir/ir/$module.o" "$build_dir/ir/$module.c"
}

cd "$project_dir"
lean --version
shared_modules=(LeanOntology/Path LeanOntology/Validation LeanOntology/Identity LeanOntology/Schema
  LeanOntology/Codec LeanOntology/Descriptor LeanOntology/Query LeanOntology LeanContract/Operation LeanContract/Transport
  LeanContract/Http LeanContract/CallFailure LeanContract/Channel LeanContract LeanApp/Context LeanApp/Capability LeanApp/Binding
  LeanApp/Policy LeanApp/Module LeanApp/Application LeanApp/Channel LeanApp/Testing LeanApp
  Examples/Tickets/Domain Examples/Tickets/Contracts)
shared_objects=()
for module in "${shared_modules[@]}"; do
  if [[ "$module" == Examples/* ]]; then
    source_dir="$project_dir/examples/lean"
  else
    source_dir="$project_dir/engine"
  fi
  compile_module "$module" "$source_dir/$module.lean" "$source_dir"
  shared_objects+=("$build_dir/ir/$module.o")
done
if [[ "${1:-}" == "--contracts-only" ]]; then
  echo "Public contracts compiled: $build_dir/lib/lean/Examples/Tickets/Contracts.olean"
  exit 0
fi

for module in LeanAppNative/Sha256 LeanAppNative/Log LeanAppNative/Metrics LeanAppNative/Server LeanAppNative/Client; do
  compile_module "$module" "$adapter_dir/$module.lean" "$adapter_dir"
  shared_objects+=("$build_dir/ir/$module.o")
done

native_modules=(NativeTickets/Storage NativeTickets/Registration NativeTickets/Http NativeTickets/Client NativeTickets NativeTickets/Checks)
for module in "${native_modules[@]}"; do
  compile_module "$module" "$native_dir/$module.lean" "$native_dir"
  shared_objects+=("$build_dir/ir/$module.o")
done

dependency_objects=()
while IFS= read -r object; do dependency_objects+=("$object"); done < <(
  rg --files --hidden "$db_dir/.lake/build/ir" "$sqlite_dir/.lake/build/ir" "$http_dir/.lake/build/ir" -g '*.c.o.export' | sort)
for object in "${dependency_objects[@]}"; do
  if ! test -f "$object"; then
    echo "Missing cached native object: $object" >&2
    echo "Dependency build: (cd adapters/native && lake build LeanDb LeanHttp)" >&2
    exit 2
  fi
done

for pair in 'ServerMain:tickets_server' 'ProtocolMain:tickets_protocol' \
  'CheckMain:tickets_checks' 'HttpCheckMain:tickets_http_checks'; do
  module="${pair%%:*}"
  executable="${pair#*:}"
  compile_module "$module" "$native_dir/$module.lean" "$native_dir"
  leanc -o "$build_dir/bin/$executable" "$build_dir/ir/$module.o" \
    "${shared_objects[@]}" "${dependency_objects[@]}" \
    "$sqlite_dir/.lake/build/lib/libleansqlite.a" "$http_dir/.lake/build/lib/libleanhttp.a" \
    -lLean -lStd -lLake
  echo "Built $build_dir/bin/$executable"
done
