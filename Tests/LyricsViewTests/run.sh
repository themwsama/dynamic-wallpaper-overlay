#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/LyricsViewTests" "$ROOT/Sources/LyricsView.swift" "$ROOT/Tests/LyricsViewTests/shim.swift" "$ROOT/Tests/LyricsViewTests/main.swift" 2>&1
"$TMP/LyricsViewTests"
