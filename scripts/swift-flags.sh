#!/usr/bin/env bash
# Swift language flags shared by scripts/build.sh and every Tests/*/run.sh, so the
# app and the tests always compile under the same concurrency rules.
# Swift 6 language mode (strict concurrency, runtime isolation checks) with
# main-actor default isolation: anything that runs off main (audio IO, script
# queue, URLSession completions) must be marked `nonisolated` explicitly.
# Bash 3.2 compatible; sourced, not run.
SWIFT_FLAGS=(-swift-version 6 -default-isolation MainActor)
