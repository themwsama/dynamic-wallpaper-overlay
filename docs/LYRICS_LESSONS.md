# Lyrics: lessons learned

A record of every mistake made while building the lyrics feature, so the
next person (or AI agent) doesn't repeat them. **Read this before changing any
lyrics code** (`LyricsProvider`, `LyricsController`, `LyricsView`,
`PlaybackClock`, `SpotifyWatcher`). After fixing a lyrics bug, add an entry.

Never paste real lyrics into this file, logs, tests or chat. Use line counts
and invented text.

## How lyrics reach the screen

A line is visible only when **all** of these hold. Debug by checking each one
in order. Don't guess.

1. **Track known.** `SpotifyWatcher` has fired `onTrackChange` for the current
   track. That needs a Spotify notification, or the launch-time query.
2. **Lyrics loaded.** `LyricsProvider` returned `.found` for that track ID.
   It must be the *current* track ID, not a stale completion.
   A cache hit applies at once; otherwise the lookup starts only after the track
   has stayed current for `LYRICS_FETCH_DEBOUNCE` (0.6 s), so "no lyrics yet" for
   the first moments of a track is expected (the trace says `2-lookup-pending`).
3. **Playing.** `isPlaying` is true and the Lyrics tile is on.
4. **Position known.** `PlaybackClock.position()` is non-nil and moving. It's
   nil only before the first anchor; after `reset()` it is *frozen at 0* (not
   nil) until a notification position or a poll syncs it.
5. **Inside a line.** `lineIndex(at: position + LYRICS_LEAD)` is non-nil and
   the line text isn't empty. Instrumental gaps are intentionally blank. The time
   before the first sung line (the intro) and a pending lookup show the title and
   artist placeholder instead; a song with no lyrics (`.none`) stays empty.
6. **Drawn.** `LyricsView` is visible (root opacity), its window is ordered
   front, and the line's layers weren't removed by a late cleanup. It must be
   the view that exists *now*: a display change rebuilds every window, and the
   new `LyricsView`s start hidden and empty.

## Mistakes so far

| # | Symptom | Root cause | Lesson |
|---|---|---|---|
| 1 | "I don't see lyrics" after the feature was announced | The data layer shipped, but the renderer (`LyricsView`) wasn't built yet | Don't report a feature as working until it's visible end to end |
| 2 | Next song showed no lyrics | A plain-lyrics-only `/api/get` result was treated as "no lyrics", and that was cached for 7 days | A partial answer isn't a definitive miss; fall through before caching a negative |
| 3 | No lyrics during LRCLIB outages | HTTP 503 wasn't retried | Retry 5xx/429/timeouts with backoff; never cache transient failures |
| 4 | Wrong song's lyrics (found in review) | The search fallback took `synced.first` without checking the title; cached forever | Require a title match plus an artist or duration match; return `.none` otherwise |
| 5 | Old line flashed on track change | `onStateChange` fired before `onTrackChange` | Fire the track change first; update all state before any callback |
| 6 | Lyrics drifted after seeking, until restart | `PlaybackClock` disabled polling permanently after 3 failures | Back off, never disable; recover on success |
| 7 | Lyrics jumped after a track change | A poll started on the old track was applied after `reset()` | Stamp polls with an epoch; drop stale results |
| 8 | Karaoke sweep ended early | The entry delay was subtracted twice | Keep timing math in a pure function, with tests |
| 9 | Some lines missing | The LRC parser rejected `[t1] [t2] text` with a space | Parse what real files contain, not just the spec |
| 10 | No lyrics when the overlay started mid-song | The track was only learned from change notifications | Query Spotify once at launch |
| 11 | Songs with only plain lyrics stayed blank | Plain text was ignored | Show it with estimated timing and mark it "approximate" |
| 12 | Lyrics sometimes show, sometimes don't (2026-10-16): fetched for every song, but the box stayed empty for the rest of a song | Condition 6. A display change (`didChangeScreenParametersNotification`, which also fires on a 1-pixel `visibleFrame` change, e.g. the Dock or menu bar, and on external-display wake) makes `OverlayController.rebuild()` replace every `LyricsView`. The new views start at opacity 0 and empty. `LyricsController` never told them: `setVisible` only runs on a play, lyrics or setting change, and `tick()` skipped the redraw because `shownIndex` still matched the line drawn on the *old* view. Recovery only came with the next pause, toggle or song with lyrics. The live log showed about 9 rebuilds in 20 minutes on the user's two-display setup | State the controller remembers about a view is only valid for that view instance. `tick()` now notices replaced views (by identity), fades them in and redraws the line. `Tests/LyricsControllerTests` replays real event sequences through the real controller and clock and asserts "playing inside a line ⇒ line shown within one tick" |
| 13 | Lyrics slow or late after skipping songs fast (2026-10-16): lyrics for the song landed on arrived up to 6.9 s late. Also, right after a change the box was empty for the intro and looked broken | Cause 1: every track change fired an LRCLIB request at once, even for tracks skipped within 0.3 s (about 10 requests in 10 s). LRCLIB answered the burst with HTTP 503, and the song the user landed on then sat through the provider's retries. Nothing was cancelled, so requests and retry timers for skipped songs kept running and kept the burst going. **This was only part of the cause:** LRCLIB returns 503 in spikes whatever we do. A later trace with no skipping at all showed 3 get 503s on one track change (183 get and 113 search 503s in one day's log), while spaced-out manual probes got 200 in 0.2-0.6 s. Skip bursts made the spikes worse and longer for the user; they did not cause them (see #14). Cause 2: not a bug. Condition 5 is correct before the first timestamp (`5-between-lines` in the trace), but an empty box for a few seconds after a change looks the same as "lyrics are broken" | Don't turn every UI event into a network request: wait until the track has stayed current for `LYRICS_FETCH_DEBOUNCE` (0.6 s), but apply a cache hit at once (`cachedLyrics(trackID:)`, no network). Cancel work for superseded targets, keyed by ID: `LyricsProvider.cancel(trackID:)` stops the `URLSessionTask`s and the retry and budget timers, drops that track's waiters silently, never writes a negative cache entry and never touches another track; the controller cancels its debounce and retry timers too. Assume the server is flaky even when we behave: 503s come in spikes, so the lookup policy must survive them on its own. "Correct but looks broken" is a bug for the user: the box shows the title and artist (small, 60% alpha, no sweep) while a lookup is pending and in the song's intro (start of the song only, never in mid-song gaps, never for `.none`). `Tests/LyricsControllerTests` replays "8 skips 0.3 s apart, the 9th stays" and asserts one lookup, for the 9th track |
| 14 | A single track change with no skipping still took 13 s to get lyrics (2026-10-16): `/api/get` got HTTP 503 three times, with provider retries at 1.5 s and 4 s, before the lookup fell through to `/api/search` | The lookup was a chain: get, then (only after get gave up) search. A 503-prone endpoint was retried for about 5.5 s before the other endpoint was even tried, although `/api/search` was answering in 0.2-0.6 s. The debounce (#13) cannot help here: it is one request for one track | Don't serialize independent fallbacks behind a flaky one: race them. `LyricsProvider` fires `/api/get` and `/api/search` together. An acceptable synced result from either ends the lookup at once and cancels the other request (get's exact match first if both are synced). Plain, empty or failed from one endpoint waits for the other, up to its own retry budget. Each endpoint retries only 5xx, 429 and transport errors, with short jittered backoff (0.4 s, 1.2 s, 3 s, +-30%, injectable), and a whole lookup is decided by `LYRICS_LOOKUP_BUDGET` (8 s). Only answers where neither endpoint failed are cached: a plain result shown while the other endpoint failed is not cached (so a later lookup can find synced lyrics), and a failure never is. A small circuit breaker (more than 5 consecutive 5xx within 30 s, across lookups) skips `/api/get` for 60 s. Tests: `Tests/LyricsProviderTests`, section "race" and "jitter, budget, breaker" |

## Process mistakes

- **Fixed symptoms, not causes.** Each fix addressed one observed failure
  without a way to see which of the 6 conditions above failed at the moment
  the box was empty.
- **No end-to-end check.** The tests covered parsing and fetching with stubs.
  Nothing checked "position X in a song with lyrics ⇒ a line is visible", and
  nobody watched the live screen.
- **Accepted the first diagnosis from one trace.** Row 13 blamed LRCLIB's 503s
  on skip bursts after looking at one skipping trace, and was never re-checked
  against a trace with no skipping. A later no-skip trace showed the same 503s
  and a 13 s lookup (row 14). Before writing a root cause down, find a trace
  where the supposed cause is absent and see whether the symptom survives.
- **Parallel agents without shared memory.** Several agents changed lyrics
  code in parallel with no record like this one, so knowledge was lost
  between fixes.

## How #12 was found

The replay test (`Tests/LyricsControllerTests`) drove 16 scenarios: normal play,
seeks with and without a broadcast, pause/resume (also faster than the fade),
a long pause, skips, a song without lyrics, a broadcast without a position, polls
denied, a track change while fetching, estimated lyrics, the Lyrics tile, and
window rebuilds while playing and while paused. Only "windows rebuilt while playing" failed on the old code:
the views stayed `visible=false` with no line while the trace said `shown`. The
other suspects (the delayed `removeLine` after a fade, Paused/Playing pairs,
`LYRICS_LEAD` boundaries, stale lookups) held up. Then a read-only listener
caught a `didChangeScreenParametersNotification` at the same second as the live
app's instant "wallpaper hidden"/"wallpaper visible" log pair (both lines in the
same millisecond). That pair shows up about 9 times in 20 minutes of the live log,
so the rebuild happens often, mid-song.

## Rules for the next fix

1. **Reproduce first.** Turn on the lyrics trace (`WALLPAPER_OVERLAY_TRACE_LYRICS=1`
   in the LaunchAgent's environment), which logs which condition failed when the
   box is empty, once per change (`lyrics trace <n>-<condition> index= visible=
   shownIndex= position=`, never lyric text), plus `views replaced` on a rebuild. Then name the
   failing condition.
2. **Write a failing test** that replays the real event sequence (fake Spotify
   notifications, plus fake clock and poll results) through `LyricsController`.
   Add the scenario to `Tests/LyricsControllerTests`.
   Then fix.
3. **Verify on the live app** with the trace, over several songs including
   seeks, pauses and skips. Then add a row to the table above.
