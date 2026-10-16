# Tests

Each suite is a standalone assert-style runner (`PASS`/`FAIL` lines, exit 1 on failure). Run one with `Tests/<Name>/run.sh`; each compiles only the `Sources/*.swift` files it needs into a temp dir. Tests use temp dirs or UserDefaults suites, never `~/.config`.

- `AudioAnalyzerTests`: beat/tempo detection on synthetic audio signals.
- `ClockModelTests`: clock/timer model state and timer minute limits.
- `GenreResolverTests`: genre lookup, mapping, caching and fallback order with stubbed network.
- `HousekeepingTests`: cache pruning by age/count and in-place log trimming.
- `LyricsProviderTests`: LRC parsing, LRCLIB requests, retries, caching and romaji with a stubbed URLSession (invented lyrics only).
- `PlaybackClockTests`: playback position interpolation and Spotify resync behaviour.
- `SettingsTests`: persisted settings defaults and round-trips via a throwaway UserDefaults suite.
- `SpotifyWatcherTests`: Spotify notification parsing and track/state change handling.
