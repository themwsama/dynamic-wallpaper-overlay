#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/SettingsTests" "$ROOT/Sources/Settings.swift" "$ROOT/Tests/SettingsTests/main.swift" 2>&1
"$TMP/SettingsTests"
