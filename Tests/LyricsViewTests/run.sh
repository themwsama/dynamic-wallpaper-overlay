#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/LyricsViewTests" "$ROOT/Sources/LyricsView.swift" "$ROOT/Tests/LyricsViewTests/shim.swift" "$ROOT/Tests/LyricsViewTests/main.swift" 2>&1
"$TMP/LyricsViewTests"
