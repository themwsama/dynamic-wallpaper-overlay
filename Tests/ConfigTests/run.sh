#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/ConfigTests" "$ROOT/Sources/Style.swift" "$ROOT/Sources/Config.swift" "$ROOT/Sources/TextBlock.swift" "$ROOT/Tests/ConfigTests/main.swift" 2>&1
"$TMP/ConfigTests"
