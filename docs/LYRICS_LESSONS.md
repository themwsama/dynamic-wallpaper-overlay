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
3. **Playing.** `isPlaying` is true and the Lyrics tile is on.
4. **Position known.** `PlaybackClock.position()` is non-nil and moving. It's
   nil only before the first anchor; after `reset()` it is *frozen at 0* (not
   nil) until a notification position or a poll syncs it.
5. **Inside a line.** `lineIndex(at: position + LYRICS_LEAD)` is non-nil and
   the line text isn't empty. Instrumental gaps and the time before the first
   timestamp are intentionally blank.
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

## Process mistakes

- **Fixed symptoms, not causes.** Each fix addressed one observed failure
  without a way to see which of the 6 conditions above failed at the moment
  the box was empty.
- **No end-to-end check.** The tests covered parsing and fetching with stubs.
  Nothing checked "position X in a song with lyrics ⇒ a line is visible", and
  nobody watched the live screen.
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
