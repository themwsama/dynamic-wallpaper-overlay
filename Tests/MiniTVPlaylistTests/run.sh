#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/MiniTVPlaylistTests" "$ROOT/Sources/MiniTVPlaylist.swift" "$ROOT/Tests/MiniTVPlaylistTests/main.swift" 2>&1
"$TMP/MiniTVPlaylistTests"
