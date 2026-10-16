#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/HousekeepingTests" "$ROOT/Sources/Housekeeping.swift" "$ROOT/Sources/Style.swift" "$ROOT/Sources/Config.swift" "$ROOT/Tests/HousekeepingTests/main.swift" 2>&1
"$TMP/HousekeepingTests"
