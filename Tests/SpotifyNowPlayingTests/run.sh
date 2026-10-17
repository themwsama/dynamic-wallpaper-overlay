#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/SpotifyNowPlayingTests" "$ROOT/Sources/SpotifyWatcher.swift" "$ROOT/Sources/PlaybackClock.swift" "$ROOT/Tests/SpotifyNowPlayingTests/main.swift" 2>&1
"$TMP/SpotifyNowPlayingTests"
