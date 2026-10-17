# Tests

Each suite is a standalone assert-style runner (`PASS`/`FAIL` lines, exit 1 on failure). Run one with `Tests/<Name>/run.sh`; each compiles only the `Sources/*.swift` files it needs into a temp dir. Tests use temp dirs or UserDefaults suites, never `~/.config`.

Run them all with `scripts/run-tests.sh` (one PASS/FAIL line per suite; add `-v` or `--verbose` for full output of every suite).

- `AudioAnalyzerTests`: beat/tempo detection on synthetic audio signals.
- `ClockModelTests`: clock/timer model state and timer minute limits (compiles `ClockModel.swift` alone; limits come through `init`).
- `ConfigTests`: `config.json` per-key tolerance, validation, video path resolution, the overlay-dir env override and subtitle fitting.
- `GenreResolverTests`: genre lookup, mapping, caching and fallback order with stubbed network.
- `HousekeepingTests`: cache pruning by age/count and in-place log trimming.
- `LyricsProviderTests`: LRC parsing, LRCLIB requests, retries, caching and romaji with a stubbed URLSession (invented lyrics only).
- `MusicSessionTests`: `MusicSession` driven by fake Spotify playback notifications posted to an injected `NotificationCenter`, with a canned AppleScript runner, app-running check and stubbed tap build: track/position/play-state callbacks, quit (reset and ended), the launch bootstrap (only when Spotify runs and no track is known yet), and the audio-tap grace suspend through an injected scheduler (no sleeping).
- `LyricsControllerTests`: end-to-end replay through the real `LyricsController`, `PlaybackClock`, `MusicSession` and `SpotifyWatcher`, with fake Spotify notifications, a fake clock and poll answers, a fake lyrics lookup and views that record what they show. Every step asserts "playing inside a non-empty line ⇒ that line is visible within one tick": play, seeks, pauses, skips, missing positions, denied polls, late lookups, estimated lyrics, the Lyrics tile and window rebuilds. Also checks the `WALLPAPER_OVERLAY_TRACE_LYRICS` trace (one line per change, no lyric text). Takes about 30 s (real ticks).
- `LyricsViewTests`: karaoke sweep timing arithmetic for lyric rows (pure math, no rendering).
- `PlaybackClockTests`: playback position interpolation, resync and poll backoff with a fake `SpotifyPositionSource`.
- `SettingsTests`: persisted settings defaults and round-trips via a throwaway UserDefaults suite (UUID name; `run.sh` deletes the domain and its plist afterwards).
- `SpotifyNowPlayingTests`: parsing of the launch-time now-playing output (text fields, number and decimal-separator handling, junk input) with invented track data.
- `SpotifyWatcherTests`: `SpotifyWatcher` notification parsing, track/state change handling, reset, and the injected notification center, app-running check and script runner behind the launch query.
