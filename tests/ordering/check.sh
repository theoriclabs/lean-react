#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p tests/ordering/.build/tests/ordering
lake build Ordering
export LEAN_PATH="$PWD/tests/ordering/.build${LEAN_PATH:+:$LEAN_PATH}"
lake env lean tests/ordering/Positive.lean
lake env lean -o tests/ordering/.build/tests/ordering/Fixtures.olean tests/ordering/Fixtures.lean
lake env lean tests/ordering/GenerateDomain.lean
lake env lean --run tests/ordering/Native.lean > tests/ordering/.build/native.json
node --test tests/ordering/parity.test.mjs
for fixture in tests/ordering/negative/*.lean; do
  name="$(basename "$fixture" .lean)"
  log="tests/ordering/.build/$name.log"
  if lake env lean "$fixture" > "$log" 2>&1; then
    echo "FAIL: $name unexpectedly compiled" >&2
    exit 1
  fi
  case "$name" in
    Wrong*) pattern='Application type mismatch' ;;
    PrivateStock) pattern='Unknown constant `Ordering.Stock.mk`' ;;
    PrivateConfiguration) pattern='Unknown constant `Ordering.AdmissibleConfiguration.mk`' ;;
    PrivateQuote) pattern='Unknown constant `Ordering.Quoted.mk`' ;;
    PrivateMemory) pattern='Unknown constant `Ordering.Memory.mk`' ;;
    *Update) pattern='is marked as private' ;;
    *) echo "FAIL: no expected diagnostic for $name" >&2; exit 1 ;;
  esac
  if ! rg -Fq "$pattern" "$log"; then
    cat "$log" >&2
    echo "FAIL: $name failed for an unexpected reason" >&2
    exit 1
  fi
  echo "PASS: rejected $name"
done
