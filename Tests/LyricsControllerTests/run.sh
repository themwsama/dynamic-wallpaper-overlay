#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
SUITE="wallpaper-overlay-lyrics-test-$(uuidgen)"
# Same cleanup as SettingsTests: cfprefsd can leave the plist behind
cleanup() {
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  rm -rf "$TMP"
}
trap cleanup EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/LyricsControllerTests" \
  "$ROOT/Sources/LyricsController.swift" "$ROOT/Sources/LyricsView.swift" "$ROOT/Sources/LyricsProvider.swift" \
  "$ROOT/Sources/PlaybackClock.swift" "$ROOT/Sources/Settings.swift" "$ROOT/Sources/MusicSession.swift" \
  "$ROOT/Sources/SpotifyWatcher.swift" "$ROOT/Sources/SpotifyAudioTap.swift" "$ROOT/Sources/AudioAnalyzer.swift" \
  "$ROOT/Tests/LyricsViewTests/shim.swift" "$ROOT/Tests/LyricsControllerTests/main.swift" 2>&1
"$TMP/LyricsControllerTests" "$SUITE"
