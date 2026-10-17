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
4. **Position known.** `PlaybackClock.position()` is non-nil. It's nil until
   the first sync after `reset()`.
5. **Inside a line.** `lineIndex(at: position + LYRICS_LEAD)` is non-nil and
   the line text isn't empty. Instrumental gaps and the time before the first
   timestamp are intentionally blank.
6. **Drawn.** `LyricsView` is visible (root opacity), its window is ordered
   front, and the line's layers weren't removed by a late cleanup.

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
| 12 | Lyrics sometimes show, sometimes don't (open, 2026-10-16) | Under investigation, see below | |

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

## Rules for the next fix

1. **Reproduce first.** Turn on the lyrics trace (`WALLPAPER_OVERLAY_TRACE_LYRICS=1`),
   which logs which condition failed when the box is empty. Then name the
   failing condition.
2. **Write a failing test** that replays the real event sequence (fake Spotify
   notifications, plus fake clock and poll results) through `LyricsController`.
   Then fix.
3. **Verify on the live app** with the trace, over several songs including
   seeks, pauses and skips. Then add a row to the table above.
