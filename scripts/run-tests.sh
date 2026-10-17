#!/usr/bin/env bash
# Run every Tests/*/run.sh. Quiet by default: one PASS/FAIL line per suite,
# full output only for failures or with -v/--verbose.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0
case "${1:-}" in
  -h|--help) echo "Usage: $(basename "$0") [-v|--verbose]  (runs every Tests/*/run.sh)"; exit 0 ;;
  -v|--verbose) VERBOSE=1 ;;
  "") ;;
  *) echo "error: unknown option: $1" >&2; exit 2 ;;
esac

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
passed=0; failed=0; failures=""
for t in "$REPO"/Tests/*/run.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$(dirname "$t")")"
  if bash "$t" >"$LOG" 2>&1; then
    passed=$((passed+1)); echo "PASS $name"
    (( VERBOSE == 0 )) || sed 's/^/    /' "$LOG"
  else
    failed=$((failed+1)); failures="$failures $name"; echo "FAIL $name"
    sed 's/^/    /' "$LOG"
  fi
done

if (( passed + failed == 0 )); then echo "no tests found (Tests/*/run.sh)"; exit 0; fi
echo "---- $passed passed, $failed failed"
(( failed == 0 )) || { echo "failed:$failures" >&2; exit 1; }
