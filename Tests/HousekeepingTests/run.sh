#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/HousekeepingTests" "$ROOT/Sources/Housekeeping.swift" "$ROOT/Sources/Style.swift" "$ROOT/Sources/Config.swift" "$ROOT/Tests/HousekeepingTests/main.swift" 2>&1
"$TMP/HousekeepingTests"
