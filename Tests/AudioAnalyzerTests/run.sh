#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/AudioAnalyzerTests" "$ROOT/Sources/AudioAnalyzer.swift" "$ROOT/Tests/AudioAnalyzerTests/main.swift" 2>&1
"$TMP/AudioAnalyzerTests"
