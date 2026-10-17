#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
SUITE="wallpaper-overlay-settings-test-$(uuidgen)"
# removePersistentDomain empties the domain but cfprefsd can leave the plist
# behind, so delete the domain and the file too
cleanup() {
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  rm -rf "$TMP"
}
trap cleanup EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/SettingsTests" "$ROOT/Sources/Settings.swift" "$ROOT/Tests/SettingsTests/main.swift" 2>&1
"$TMP/SettingsTests" "$SUITE"
