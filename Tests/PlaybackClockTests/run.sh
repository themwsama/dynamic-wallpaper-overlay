#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/PlaybackClockTests" "$ROOT/Sources/PlaybackClock.swift" "$ROOT/Tests/PlaybackClockTests/shim.swift" "$ROOT/Tests/PlaybackClockTests/main.swift" 2>&1
"$TMP/PlaybackClockTests"
