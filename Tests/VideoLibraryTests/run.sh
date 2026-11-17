#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/swift-flags.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "${SWIFT_FLAGS[@]}" -o "$TMP/VideoLibraryTests" "$ROOT/Sources/MiniTVPlaylist.swift" "$ROOT/Sources/VideoImporter.swift" "$ROOT/Sources/VideoLibrary.swift" "$ROOT/Tests/VideoLibraryTests/main.swift" 2>&1
"$TMP/VideoLibraryTests"
