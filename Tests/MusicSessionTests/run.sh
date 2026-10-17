#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/MusicSessionTests" "$ROOT/Sources/MusicSession.swift" "$ROOT/Sources/SpotifyWatcher.swift" "$ROOT/Sources/PlaybackClock.swift" "$ROOT/Sources/SpotifyAudioTap.swift" "$ROOT/Sources/AudioAnalyzer.swift" "$ROOT/Tests/MusicSessionTests/main.swift" 2>&1
"$TMP/MusicSessionTests"
