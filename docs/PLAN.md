# Plan: shipping Dynamic Wallpaper Overlay to other people

The goal: anyone with a Mac can clone this repo, point their AI agent at
`AGENTS.md` (or run one script), and end up with a live video wallpaper,
personal name block, settings gear, and Spotify glow and lyrics, with no
third-party wallpaper app and no personal data from the original author.

## Status

| Phase | Status |
|---|---|
| 1. Extract from the author's install | Done: sources copied, personal strings moved to `config.json` |
| 2. Standalone wallpaper pipeline | Done: `make-wallpaper.sh`, `make-sample-video.sh`, optional desktop still |
| 3. One-shot installer and uninstaller | Done: `install.sh`, `uninstall.sh`, `DRY_RUN=1` |
| 4. Tests in the repo | Done: `Tests/*`, `scripts/run-tests.sh` |
| 5. Agent and human docs | Done: `AGENTS.md`, `README.md`, this plan |
| 6. GitHub repository | Done: https://github.com/themwsama/dynamic-wallpaper-overlay |
| 7. CI | Next |
| 8. Signed releases | Later |
| 9. Feature roadmap | Ongoing |

Review fixes (done).

Wave 3 is next:

- Swift 6 strict concurrency.
- A stable local signing identity.
- A `NowPlayingSource` seam.
- `Package.swift` with swift-testing.

## Phase 1: Extraction (done)

- All Swift and Metal sources live in `Sources/`.
- Personal values (name, subtitle, nixie number, fonts, video path) moved from
  constants into `Config.swift`, read from `~/.config/wallpaper-overlay/config.json`.
- Every author-specific identifier was renamed: log prefix, Keychain service,
  queue labels, app ID (`local.wallpaper-overlay`, overridable with `BUNDLE_ID`),
  paths.
- **Nothing personal is shipped:** no videos or artwork, no caches, no lyrics,
  no logs, no binary. `.gitignore` enforces this.

## Phase 2: Standalone wallpaper (done)

- The overlay already renders the video itself; the old dependency on a
  third-party wallpaper app is gone.
- `make-wallpaper.sh` turns any clip into the stacked format: the original on
  top, the glass version (blur, saturation, gradient tint, sheen) below, at
  2560×2880 H.264 with no audio.
- `--set-desktop` also sets a still frame as the macOS desktop picture, for
  login, Mission Control, and the first moment before the video starts.
- `make-sample-video.sh` makes an original abstract loop, so a fresh install
  works with no media at all.

## Phase 3: Installer (done)

- `install.sh` checks requirements, writes the config, builds the wallpaper and
  the app, installs the LaunchAgent, and explains the permissions.
- It's idempotent: re-running it is safe, and it never overwrites `config.json`
  without `--force-config`.
- `uninstall.sh` removes everything except Keychain items, and prints the
  commands to remove those too.

## Phase 4: Tests (done)

- Plain executable suites, no XCTest needed, so they run on Command Line Tools
  alone. Network is stubbed; lyrics in tests are invented.

## Phase 5: Docs (done)

- `AGENTS.md`: model-agnostic agent guide covering rules, the setup questions,
  install, permissions, architecture, customization recipes, verification and
  troubleshooting.
- `README.md`: human quick start.

## Phase 6: GitHub repository (done)

Published at https://github.com/themwsama/dynamic-wallpaper-overlay.

1. Create the repo under the owner's account; visibility is the owner's choice. (Done)
2. Push `main` with the initial commit. (Done)
3. Add topics (`macos`, `wallpaper`, `metal`, `spotify`, `swift`) and a short
   description. (Open)
4. Optionally add a demo GIF made from the **sample** wallpaper only, in
   `docs/images/`. (Open)

## Phase 7: CI (next)

GitHub Actions on `macos-26` runners (once available; until then the newest
macOS image, with the macOS-26-only APIs behind `#available` checks as they
are today):

- `swiftc -typecheck Sources/*.swift`
- `scripts/run-tests.sh`
- `bash -n scripts/*.sh` and `shellcheck`
- Compile `Transition.metal` with `xcrun metal` as a syntax check.

## Phase 8: Signed releases (later)

- Developer ID signing and notarization, so permission grants survive updates
  and Gatekeeper doesn't warn.
- A prebuilt `.app` zip on GitHub Releases, plus an optional Homebrew cask that
  runs the same LaunchAgent setup.
- A `--version` flag and an update check.

## Phase 9: Feature roadmap

| Idea | Notes |
|---|---|
| Playlist of wallpapers / time-of-day switching | Several stacked videos; reuse the transitions between them |
| Per-display wallpapers | `ScreenWindows` already per screen; renderer needs per-view frame sources |
| Apple Music support | `com.apple.Music.playerInfo` distributed notification; process tap on `com.apple.Music` |
| In-app editing of name/subtitle | A control-center tile opening a small glass text editor; write `config.json` |
| More lyric styles | "Brush reveal" and "Scatter assemble" were prototyped in Claude Design |
| Live wallpaper switcher | Drag a video onto the gear to run `make-wallpaper.sh` in the background |
| Localization | Subtitle and tile labels; font fallbacks for CJK names |
