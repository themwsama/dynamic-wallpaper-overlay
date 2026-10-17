#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/PlaybackClockTests" "$ROOT/Sources/PlaybackClock.swift" "$ROOT/Tests/PlaybackClockTests/main.swift" 2>&1
"$TMP/PlaybackClockTests"
