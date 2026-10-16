#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/LyricsProviderTests" "$ROOT/Sources/LyricsProvider.swift" "$ROOT/Tests/LyricsProviderTests/main.swift" 2>&1
"$TMP/LyricsProviderTests"
