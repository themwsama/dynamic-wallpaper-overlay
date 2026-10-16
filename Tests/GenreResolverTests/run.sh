#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -o "$TMP/GenreResolverTests" "$ROOT/Sources/GenreResolver.swift" "$ROOT/Tests/GenreResolverTests/main.swift" 2>&1
"$TMP/GenreResolverTests"
