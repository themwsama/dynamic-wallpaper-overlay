#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/ClockModelTests" "$ROOT/Sources/ClockModel.swift" "$ROOT/Tests/ClockModelTests/main.swift" 2>&1
"$TMP/ClockModelTests"
