#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/MusicSessionTests" "$ROOT/Sources/MusicSession.swift" "$ROOT/Sources/SpotifyWatcher.swift" "$ROOT/Sources/PlaybackClock.swift" "$ROOT/Sources/SpotifyAudioTap.swift" "$ROOT/Sources/AudioAnalyzer.swift" "$ROOT/Tests/MusicSessionTests/main.swift" 2>&1
"$TMP/MusicSessionTests"
