# Tests

Each suite is a standalone assert-style runner (`PASS`/`FAIL` lines, exit 1 on failure). Run one with `Tests/<Name>/run.sh`; each compiles only the `Sources/*.swift` files it needs into a temp dir. Tests use temp dirs or UserDefaults suites, never `~/.config`.

Run them all with `scripts/run-tests.sh` (one PASS/FAIL line per suite; add `-v` or `--verbose` for full output of every suite).

- `AudioAnalyzerTests`: beat/tempo detection on synthetic audio signals.
- `ClockModelTests`: clock/timer model state and timer minute limits.
- `ConfigTests`: `config.json` per-key tolerance, validation, video path resolution, the overlay-dir env override and subtitle fitting.
- `GenreResolverTests`: genre lookup, mapping, caching and fallback order with stubbed network.
- `HousekeepingTests`: cache pruning by age/count and in-place log trimming.
- `LyricsProviderTests`: LRC parsing, LRCLIB requests, retries, caching and romaji with a stubbed URLSession (invented lyrics only).
- `LyricsViewTests`: karaoke sweep timing arithmetic for lyric rows (pure math, no rendering).
- `PlaybackClockTests`: playback position interpolation and Spotify resync behaviour.
- `SettingsTests`: persisted settings defaults and round-trips via a throwaway UserDefaults suite.
- `SpotifyNowPlayingTests`: parsing of the launch-time now-playing output (text fields, number and decimal-separator handling, junk input) with invented track data.
- `SpotifyWatcherTests`: Spotify notification parsing and track/state change handling.
