# AGENTS.md: Dynamic Wallpaper Overlay

This file is written for AI coding agents (any model, any tool) that have been
asked to install, personalize, extend, or debug this project on a user's Mac.
Read it fully before acting. It is the single source of truth for how the
project fits together; `README.md` is the short human version.

---

## 0. TL;DR for agents

1. Confirm the machine qualifies (section 2). Stop and tell the user if it doesn't.
2. Ask the user the **four setup questions** (section 3) unless they already answered them.
3. Run `scripts/install.sh` with their answers (section 4). It's idempotent.
4. Walk the user through the **permission prompts** (section 6) and verify (section 10).
5. For any customization, find the right knob in section 8 before editing code.
6. Follow the **agent rules** in section 1 the whole time.

---

## 1. Rules for agents (read first)

- **Touching lyrics code?** Read [`docs/LYRICS_LESSONS.md`](docs/LYRICS_LESSONS.md)
  first, and add an entry after every lyrics fix. It records each past
  mistake, so you don't repeat them.

- **Never commit or publish personal data.** User videos, generated wallpapers,
  `config.json`, caches (`lyrics-cache/`, `genre-cache.json`) and logs stay on
  the user's machine. `.gitignore` already excludes them; don't override it.
- **Never print, paste, copy or summarize song lyrics** from the lyrics cache,
  LRCLIB responses or the screen into chat, files, commits or issues. Lyrics
  are fetched at runtime only to display on the user's own desktop. When
  debugging, report *counts* ("47 synced lines"), never text. Test data must be
  invented lines.
- **Media rights:** don't download wallpapers or artwork from the web for the
  user. Use the user's own video files or `scripts/make-sample-video.sh`.
- **Secrets live in the macOS Keychain**, never in files or env vars committed
  anywhere (section 7.4).
- **Ask before outward or hard-to-reverse actions:** changing the macOS desktop
  picture (`--set-desktop`), creating or modifying LaunchAgents, deleting user
  files, or pushing to a remote.
- **Don't fight permission prompts.** macOS shows them to the user; explain
  what each is for (section 6) and let the user decide.
- **Verify, don't assume.** This app has no visible window to screenshot from a
  shell without Screen Recording permission. Use the log, `footprint`, the
  offscreen render harnesses and the tests (section 10) as evidence, and ask the
  user to look at the screen for the final check.
- **Keep the house style** when editing code (section 9.4).

---

## 2. Requirements

| Need | Why | Check |
|---|---|---|
| macOS 26 (Tahoe) or newer | Liquid Glass (`NSGlassEffectView`) and Core Audio process taps by bundle ID | `sw_vers -productVersion` |
| Swift compiler (Xcode or Command Line Tools) | builds the app | `swiftc --version` (install: `xcode-select --install`) |
| ffmpeg | converts any video into the wallpaper format | `ffmpeg -version` (install: `brew install ffmpeg`) |
| Spotify desktop app (optional) | music glow, genre colors, lyrics | `ls /Applications/Spotify.app` |
| Apple silicon or Intel | both work; Metal is required (every Mac on macOS 26 has it) | n/a |

**No third-party wallpaper app is needed.** The overlay decodes and renders the
video wallpaper itself, in a full-screen window just above the macOS desktop
picture. The installer can also set a matching still frame as the system
desktop picture, which shows at login and in Mission Control.

---

## 3. Setup questions to ask the user

Ask these once, in one message, and offer the defaults:

1. **Name** shown large in the top-right corner (default `YOUR NAME`).
2. **Short description** under it, e.g. `DESIGNER · TOKYO` (default `A SHORT DESCRIPTION`).
3. **Wallpaper video:** a path to their own video file, or the generated sample.
   Any format ffmpeg reads works; landscape clips that loop cleanly look best.
4. **Set the still frame as the macOS desktop picture too?** (Needs one System
   Events automation prompt. Recommended if they don't use another wallpaper app.)

Optional: their preferred fonts (section 8.1) and whether they use Spotify.

---

## 4. Install (the happy path)

From the repository root:

```sh
# With the user's own video:
scripts/install.sh --name "ADA LOVELACE" --subtitle "ENGINEER · LONDON" --video ~/Movies/loop.mp4 --set-desktop

# Or with the generated sample wallpaper:
scripts/install.sh --name "ADA LOVELACE" --subtitle "ENGINEER · LONDON" --sample
```

Preview without changing anything: prefix with `DRY_RUN=1`.

Optional: `scripts/install.sh --stable-signing` creates a local self-signed
code-signing identity, "Wallpaper Overlay Local Signing", so macOS permission
grants survive rebuilds (section 6). It adds a keychain item, so ask the user
first. `build.sh` signs with `SIGNING_IDENTITY` or that identity when present,
and falls back to ad-hoc.

What `install.sh` does, in order:

1. Checks macOS 26+, `swiftc` and `ffmpeg`.
2. Creates `~/.config/wallpaper-overlay/` and writes `config.json` from
   `config.example.json`, filling in name and subtitle. It never overwrites an
   existing config unless `--force-config` is passed.
3. Builds the wallpaper with `scripts/make-wallpaper.sh` from the given video,
   or from `scripts/make-sample-video.sh`.
4. Runs `scripts/build.sh`: compiles `Sources/*.swift` into
   `~/Applications/Wallpaper Overlay.app`, writes Info.plist with the usage
   descriptions, signs with `SIGNING_IDENTITY` or the local signing identity if
   present (otherwise ad-hoc), and copies `Transition.metal` next to the config.
5. Writes and loads the LaunchAgent `~/Library/LaunchAgents/local.wallpaper-overlay.plist`
   (RunAtLoad + KeepAlive), so it starts at login and restarts if it crashes.
6. Prints the permission prompts to expect and how to add optional API keys.

Environment overrides: `BUNDLE_ID` (default `local.wallpaper-overlay`),
`OUT_DIR` (default `~/Applications`), `CONFIG_DIR` (default
`~/.config/wallpaper-overlay`), `LOG_PATH` (default
`~/Library/Logs/wallpaper-overlay.log`) and `DRY_RUN` (any value except
0/false/no/off counts as on). The LaunchAgent passes `WALLPAPER_OVERLAY_DIR` and
`WALLPAPER_OVERLAY_LOG` to the app.

If you changed `BUNDLE_ID`, use your `$BUNDLE_ID` in every `launchctl` command
below instead of `local.wallpaper-overlay`.

Uninstall: `scripts/uninstall.sh`. Flags: `--keep-config` (keep the config and
wallpaper), `--yes` (skip the confirmation) and `--reset-desktop` (reset the
desktop picture if it is the overlay's still frame). It also removes the
preferences plist.

---

## 5. What the user gets

All of these sit **behind** normal app windows, like a real wallpaper:

| Feature | Behaviour |
|---|---|
| **Video wallpaper** | Seamless loop rendered with Metal, aspect-filled to every display |
| **Two looks + transitions** | "Glass" (blurred, tinted, iOS-like) or "Original"; switching plays an animated transition: *Storm rewind* (gold clock face, clockwise sweep, upward rain), *World-line shift* (nixie-tube digits and an RGB-split glitch) or a crossfade |
| **Name block** | Large serif name, a hairline rule, and the subtitle, anchored to each screen's top-right corner at a fixed margin (not baked into the video) |
| **Gear + control center** | A glass gear at the end of the subtitle row opens an iOS-style tile grid: Clock, Glass/Original, transition style, Glow, Lyrics, Romaji, and a Low power indicator. Clicking outside closes it. |
| **Clock card** | Glass stopwatch / countdown timer under the name; it slides out of the way when the control center opens |
| **Music glow** | While Spotify plays: a soft glow along the bottom edge that pulses with the real beat, colored by the song's genre, with fire sparks launched on the beat at the song's tempo |
| **Lyrics** | Time-synced lyrics in a small lower-left box with a kinetic "stagger rise" animation and a karaoke sweep in the genre color; optional romaji for Japanese. Songs LRCLIB has only as plain text show with estimated timing: no sweep, slightly dimmer, marked "♪ approximate" |
| **Efficiency** | ~200 MB memory while visible; pauses and releases all video memory when the screen sleeps or locks, or the desktop is fully covered. Each screen pauses on its own when covered. Idle rendering is capped at about 1.25× the video resolution; 30 fps cap in Low Power Mode |

---

## 6. Permissions (explain these to the user)

| Prompt | Triggered by | Used for | If denied |
|---|---|---|---|
| **System Audio Recording Only** (Privacy & Security, Screen & System Audio Recording) | Core Audio process tap on Spotify | Beat-reactive glow and tempo-driven sparks. Only Spotify's audio is tapped; each buffer is reduced to a loudness/beat number and discarded. Nothing is recorded or saved. | Glow still appears, pacing itself on the genre's typical tempo |
| **Control "Spotify"** (Automation) | AppleScript queries | Reading the current track at launch, and the playback position every 2 s so lyrics survive seeking | Lyrics sync only on play/pause/track changes |
| **Control "System Events"** (Automation) | `--set-desktop` only | Setting the still frame as the desktop picture | Skip it; the video still runs |

Screen Recording is **not** needed. There is no keyboard monitoring, and the
outside-click detection for the control center uses mouse-only event monitors,
which need no Accessibility permission.

**Rebuilds:** by default the app is signed ad-hoc, so macOS may ask for the
audio permission again after rebuilding. Re-allow it in System Settings.
`scripts/install.sh --stable-signing` avoids this (section 4).

---

## 7. Architecture

### 7.1 File map (`Sources/`)

| File | Responsibility |
|---|---|
| `main.swift` | `OverlayController`: creates the per-screen windows, wires every subsystem, owns lifecycle (rebuild on display change, visibility, audio-tap suspend) |
| `Config.swift` | Reads `~/.config/wallpaper-overlay/config.json` (name, subtitle, fonts, nixie number, video path); validates each key on its own, with safe defaults |
| `Style.swift` | All layout/look constants and window levels; personal values come from `CONFIG` |
| `Settings.swift` | UserDefaults-backed toggles (clock, glass, transition, glow, lyrics, romaji) with observers |
| `TextBlock.swift` | Draws the name, rule and subtitle; leaves room for the gear |
| `ControlCenter.swift` | Gear-opened glass panel of `TileButton`s; outside-click close |
| `ClockModel.swift`, `ClockView.swift` | Stopwatch/timer logic (timer limits injected) and the glass card; `GlassButton`, `makeGlassCard` (Liquid Glass with a blur fallback) |
| `VideoFrames.swift` | One `AVPlayerItem` looped by seek; frames as 4:2:0 `CVPixelBuffer`s |
| `TransitionRenderer.swift` | `MTKView` delegate per screen: uploads the luma/chroma planes, fills uniforms, plays transitions, frame-rate policy |
| `Transition.metal` | All GPU visuals: YUV→RGB, aspect fill, the three transitions, music glow, fire sparks. **Compiled at launch** from `~/.config/wallpaper-overlay/Transition.metal` |
| `DigitAtlas.swift` | Nixie-tube digit texture (sharp + glow channels) |
| `GlowController.swift` | Glow presence/energy/beat/colors per frame; genre → look table |
| `SpotifyWatcher.swift` | Spotify distributed notifications (`com.spotify.client.PlaybackStateChanged`, no permission); the launch-time now-playing AppleScript query; the shared Spotify script queue (`SPOTIFY_BUNDLE_ID`) |
| `SpotifyAudioTap.swift` | Core Audio process tap on Spotify (`com.spotify.client`) → `AudioAnalyzer`; rebuilds on output-device change, on a private control queue |
| `MusicSession.swift` | Owns `SpotifyWatcher` and `SpotifyAudioTap`, the 15 s pause grace period, the launch bootstrap and the Spotify-quit observer; `main.swift` wires it to genre, lyrics and glow |
| `AudioAnalyzer.swift` | Real-time-safe loudness, bass, beat onsets, tempo (median beat gap, folded into 60–180 BPM) |
| `GenreResolver.swift` | Track → genre bucket: cache, then iTunes Search (free, no key), then Spotify Web API (optional keys), then Gemini (optional key) |
| `LyricsProvider.swift` | LRCLIB client (`/api/get`, falling back to `/api/search`; plain-only lyrics get estimated timing), LRC parser, retries, on-disk cache, offline romaji via `CFStringTokenizer` |
| `PlaybackClock.swift` | Interpolated playback position; polls Spotify every 2 s while playing. Bundle ID and position source are injected, with no globals |
| `LyricsController.swift` | Picks the current line, drives `LyricsView` |
| `LyricsView.swift` | Core Animation kinetic text: per-character rise/blur-in, karaoke sweep, two-row wrap |
| `VisibilityMonitor.swift` | Sleep/lock/session/occlusion detection → pause rendering and free frames |
| `Housekeeping.swift` | Prunes the lyrics cache (60 days / 400 files) and trims the log in place (2 MB → 500 KB) every 6 h |
| `scripts/lib.sh` | Shared script helpers: env overrides, `DRY_RUN` parsing, `BUNDLE_ID` validation, default paths |

### 7.2 Windows and z-order (lowest to highest)

```
macOS desktop picture                      (system; optional still frame)
BACKDROP_LEVEL = desktopWindow + 2         Metal video + glow + sparks (click-through)
TEXT_LEVEL     = desktopWindow + 3         name block, lyrics box (click-through)
Finder desktop icons                       (desktopIconWindow)
CLOCK_LEVEL    = desktopIconWindow + 2     gear, clock card (clickable; same band as macOS widgets)
PANEL_LEVEL    = CLOCK_LEVEL + 1           control center
normal app windows                         (always above everything here)
```

Clickable windows are `ClickThroughFocusPanel`s (`.nonactivatingPanel`, can't
become key), so clicking them never steals focus from the user's app.

### 7.3 Data flow

```
MusicSession (owns SpotifyWatcher and SpotifyAudioTap; 15 s pause grace; launch bootstrap; Spotify-quit observer)
   │
   ├── SpotifyWatcher ◀──distributed notification── Spotify
   │      ├──track──▶ GenreResolver ──bucket──▶ GlowController (colors)
   │      ├──track──▶ LyricsController ──▶ LyricsProvider (LRCLIB)
   │      └──play/pause/pos──▶ PlaybackClock ◀──AppleScript poll (2 s)
   │
   └── SpotifyAudioTap ◀──audio (process tap)── Spotify
          └──▶ AudioAnalyzer ──level/beat/BPM──▶ GlowController ──uniforms──▶ Transition.metal
VideoFrames ──YUV planes──▶ TransitionRenderer ──▶ Transition.metal ──▶ MTKView per screen
Settings ◀── ControlCenter tiles          VisibilityMonitor ──▶ TransitionRenderer.setPaused
```

### 7.4 Optional API keys (Keychain)

The genre lookup works with **no keys** (iTunes Search). Keys only add fallbacks:

```sh
security add-generic-password -s wallpaper-overlay -a spotify-client-id     -w   # prompts for the value
security add-generic-password -s wallpaper-overlay -a spotify-client-secret -w
security add-generic-password -s wallpaper-overlay -a gemini-api-key        -w
launchctl kickstart -k gui/$(id -u)/local.wallpaper-overlay
```

What leaves the machine: artist, title and album names go to iTunes Search,
LRCLIB, and (if keyed) Spotify/Gemini. Audio never leaves the machine.

### 7.5 Runtime files

| Path | Contents |
|---|---|
| `~/.config/wallpaper-overlay/config.json` | Personalization (section 8.1) |
| `~/.config/wallpaper-overlay/wallpaper-stacked.mp4` | The wallpaper (section 8.2) |
| `~/.config/wallpaper-overlay/Transition.metal` | Shader source, editable live |
| `~/.config/wallpaper-overlay/genre-cache.json` | Per-track genre cache |
| `~/.config/wallpaper-overlay/lyrics-cache/` | Per-track synced lyrics (pruned automatically) |
| `~/Library/Logs/wallpaper-overlay.log` | Log (trimmed automatically) |
| `~/Library/Preferences/<bundle id>.plist` | Toggle states from the control center |

`WALLPAPER_OVERLAY_DIR` and `WALLPAPER_OVERLAY_LOG` are set only via the LaunchAgent, so launching the app by hand uses the defaults; re-run `install.sh` after changing `CONFIG_DIR` (`build.sh --install` doesn't refresh the plist).

---

## 8. Customization recipes

### 8.1 Text and fonts (no rebuild)

Edit `~/.config/wallpaper-overlay/config.json`, then restart with
`launchctl kickstart -k gui/$(id -u)/local.wallpaper-overlay`:

```json
{
  "name": "ADA LOVELACE",
  "subtitle": "ENGINEER · LONDON",
  "nixieNumber": "18.151210",
  "nameFont": "Didot",
  "subtitleFont": "Baskerville-SemiBold",
  "wallpaperVideo": "wallpaper-stacked.mp4"
}
```

- Fonts are PostScript names. List the installed ones with:
  `swift -e 'import AppKit; NSFontManager.shared.availableFonts.forEach { print($0) }'`
- Keep the name short (it's drawn at 104 pt with wide tracking). The subtitle is
  auto-tracked to the name's width, minus room for the gear.
- `nixieNumber`: digits and at most one `.`, up to 12 characters, shown in the
  World-line shift transition.
- A malformed `config.json` is logged and ignored; defaults are used.

### 8.2 Wallpaper video

```sh
scripts/make-wallpaper.sh ~/Movies/my-loop.mp4                 # writes the default path
scripts/make-wallpaper.sh clip.mov --curve 0 --blur 20           # no contrast curve, blurrier glass
scripts/make-wallpaper.sh clip.mov --set-desktop                 # also set the still as desktop picture
launchctl kickstart -k gui/$(id -u)/local.wallpaper-overlay
```

The format is fixed: **2560×2880 H.264, original on the top half, glass on the
bottom half, both 16:9, no audio.** The renderer samples one half or the other
from a single decode, which is what keeps both looks frame-locked during
transitions. If you change the half size, update `VIDEO_SIZE` in `Style.swift`.

### 8.3 Visual tuning (edit `Transition.metal`, restart, no rebuild)

| Want | Change |
|---|---|
| Spark spread/drag/curl/float | `SPARK_SPREAD`, `SPARK_DRAG`, `SPARK_CURL`, `SPARK_BUOYANCY` |
| Spark lifetime ceiling | `SPARK_MAX_HEIGHT` |
| Glow pool shapes | `musicGlow()` (`lightPool` calls) |
| Transition looks | `stormRewind()`, `worldLineShift()` |

Swift-side knobs (need `scripts/build.sh --install`):

| Want | Constant (file) |
|---|---|
| Spark count | `GLOW_SPARK_COUNT` (GlowController.swift) |
| Glow strength/height | `GLOW_INTENSITY`, `GLOW_HEIGHT` |
| Genre colors | `GENRE_LOOKS` (GlowController.swift) |
| Fade timings | `GLOW_FADE_IN_SECONDS`, `GLOW_FADE_OUT_SECONDS` |
| Transition durations | `STORM_REWIND_DURATION`, `WORLD_LINE_SHIFT_DURATION`, `CROSSFADE_DURATION` (Style.swift) |
| Margins | `MARGIN_RIGHT`, `MARGIN_TOP` (Style.swift); `LYRICS_MARGIN`, `LYRICS_BOX` (LyricsView.swift) |
| Lyric font/size/animation | `LYRICS_*` constants (LyricsView.swift) |
| Beat sensitivity | `BEAT_RATIO`, `BEAT_FLOOR` (AudioAnalyzer.swift) |

### 8.4 Adding a control-center tile

Add a `Bool` to `Settings.swift` (new `SettingKey` case; never rename existing
keys, because users have saved values), then append a `ControlTile` in
`OverlayController.makeTiles()` (`main.swift`) with an SF Symbol name, a title,
`isOn` and `action`. The panel grid sizes itself (4 columns).

### 8.5 Adding a lyric animation style

`LyricsView.show(...)` builds one `CATextLayer` per character; entry is
`animateEntry`, the karaoke sweep is `addSweep`, exit is `retireCurrentLine`.
Keep the public `show/clear/removeLine/setVisible` API so `LyricsController`
doesn't change. Respect `reducedMotion` (Low Power Mode) with a fade-only path.

### 8.6 Matching glass terminal (optional)

See `extras/wezterm/`.

---

## 9. Building, testing, conventions

### 9.1 Build

```sh
scripts/build.sh            # build the app bundle only
scripts/build.sh --install  # build and restart the running LaunchAgent
```

The shader is not compiled at build time. It ships inside the app at
`Contents/Resources/Transition.metal`. The user-editable copy at
`~/.config/wallpaper-overlay/Transition.metal` is created on the first build and
never overwritten by builds; if it differs from the repo copy, the build prints a
`diff` command to compare them. At launch, if the config-dir shader fails to
compile, the app logs the error and falls back to the bundled shader. The
overlay runs without the video backdrop only if neither copy compiles.

### 9.2 Tests

```sh
scripts/run-tests.sh
```

Each suite in `Tests/` is a plain assert-style executable (no XCTest
dependency). They cover the Spotify notification parsing, genre resolution
(stubbed HTTP), LRC parsing, LRCLIB fallback and retries, the playback clock,
settings, beat/tempo detection on synthetic audio, housekeeping and the clock
model. **Network is always stubbed; test lyrics are invented.**

### 9.3 Verifying visuals without a screenshot

The shader can be rendered offscreen to PNG with a small Metal harness: load
`Transition.metal`, upload a decoded frame (`ffmpeg -f rawvideo -pix_fmt nv12`)
as `r8Unorm` + `rg8Unorm` textures, fill `TransitionUniforms`, draw 3 vertices,
read back. Compare against `ffmpeg`'s RGB decode with the `psnr` filter
(expect more than 30 dB). `LyricsView` can be rendered with `layer.render(in:)`
using invented text.

### 9.4 Code conventions

- Header comment on every file explaining what it does.
- `UPPER_SNAKE_CASE` constants near the top of the file that uses them.
- `final class`, small focused functions, early returns.
- Comments explain *why*, not what.
- Swift 6 with `-default-isolation MainActor` (flags in `scripts/swift-flags.sh`):
  anything that runs off the main thread (the audio IO block, Core Audio
  listeners, script queues, URLSession and KVO callbacks, notifications
  posted on background queues) must be explicitly `nonisolated` /
  `@Sendable`, or it traps at runtime.
- Dev switches: `WALLPAPER_OVERLAY_NO_AUDIO_TAP=1` and
  `WALLPAPER_OVERLAY_NO_APPLESCRIPT=1` let you test-launch without permission
  prompts. `WALLPAPER_OVERLAY_TRACE_LYRICS=1` logs lyric display decisions.
- Audio-thread code (`AudioAnalyzer.process`) must not allocate or lock.
- `Uniforms` in `Transition.metal` and `TransitionUniforms` in Swift must match
  field for field (16-byte aligned `float4`s; stride 160). The app checks the
  Swift stride at startup and logs an error if the Metal buffer size differs.

---

## 10. Verification checklist

```sh
launchctl print gui/$(id -u)/local.wallpaper-overlay | grep -E "state|pid"   # running
tail -20 ~/Library/Logs/wallpaper-overlay.log                                # no "failed"
footprint $(pgrep -f "Wallpaper Overlay.app/Contents/MacOS") | head -12      # ~200 MB visible
scripts/run-tests.sh                                                         # all pass
```

Ask the user to confirm on screen: the video plays; the name block is in the
top-right; the gear opens the panel; with Spotify playing, the glow and sparks
appear within about 3 s and lyrics show in the lower-left (for songs LRCLIB
has synced).

Healthy log lines look like:

```
wallpaper-overlay: now playing <artist> – <title>
wallpaper-overlay: genre <artist> – <title> -> animeJpopGame (itunes)
wallpaper-overlay: lyrics <artist> – <title>: 47 synced lines
wallpaper-overlay: wallpaper hidden, pausing and releasing frames
```

---

## 11. Troubleshooting (real issues this project hit)

| Symptom | Cause | Fix |
|---|---|---|
| Wallpaper never changes / looks like the plain desktop | Video file missing or no decoded frames | Check `wallpaperVideo` in config and the log for `backdrop video missing`; re-run `make-wallpaper.sh` |
| Shader edit broke visuals | Metal compile error in the config-dir `Transition.metal` | The log shows the error and the bundled shader is used; fix `Transition.metal` and restart |
| Glow ignores the beat | Audio permission denied or reset by a rebuild | Re-allow "System Audio Recording Only" for Wallpaper Overlay. With no audio for 3 s, the glow falls back to the genre's tempo automatically |
| Glow stops reacting after an audio device change | Audio device changed under the process tap | The tap rebuilds automatically; no action needed. Check the log if it doesn't recover |
| Glow color never changes | Genre lookup failed | Log `genre ... (fallback)`. iTunes may rate-limit (~20/min); add Spotify/Gemini keys for fallbacks |
| No lyrics for one song | LRCLIB has no synced version, or was briefly down (503, retried twice) | Log shows `lyrics ...: none`; expected for niche tracks |
| Lyrics out of sync after seeking | Spotify Automation permission denied | Allow "control Spotify" for Wallpaper Overlay |
| Nothing for a song already playing at launch | Spotify wasn't running at launch | Play/skip once; the notification picks it up |
| Memory in the GBs | Do not convert frames to BGRA or create one video output per looping item | Keep `VideoFrames.swift`'s single item + 4:2:0 design |
| Windows doubled after plugging in a monitor | A closure capturing window structs | Capture values (e.g. points), not `ScreenWindows` |
| Text cut off on a laptop screen | Content baked into a 16:9 video gets cropped on 16:10 screens | Text is a live overlay anchored to each screen's corner; keep it that way |

---

## 12. Known limitations

- macOS 26+ only (Liquid Glass and process taps by bundle ID).
- Spotify desktop only, by design. Other players and web players aren't
  detected, and no support is planned.
- Lyrics depend on LRCLIB's community database.
- Ad-hoc signing (the default) makes permission prompts return after rebuilds.
  `install.sh --stable-signing` avoids that with a local identity. The identity
  is self-signed, untrusted and local to this Mac. Remove it with
  `security delete-identity -c "Wallpaper Overlay Local Signing"`. A Developer
  ID-signed, notarized release would be the real fix (see `docs/PLAN.md`).
- The video must be pre-processed into the stacked format.
