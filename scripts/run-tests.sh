#!/usr/bin/env bash
# Run every Tests/*/run.sh and summarize.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help) echo "Usage: $(basename "$0")  (runs every Tests/*/run.sh)"; exit 0 ;; esac

passed=0; failed=0; failures=()
for t in "$REPO"/Tests/*/run.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$(dirname "$t")")"
  echo "== $name =="
  if bash "$t"; then passed=$((passed+1)); else failed=$((failed+1)); failures+=("$name"); fi
done

if (( passed + failed == 0 )); then echo "no tests found (Tests/*/run.sh)"; exit 0; fi
echo "---- $passed passed, $failed failed"
(( failed == 0 )) || { printf 'failed: %s\n' "${failures[@]}" >&2; exit 1; }
