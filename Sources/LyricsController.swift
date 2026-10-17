// Keeps the lyric box in step with the music app: fetches lyrics (synced, or plain with
// estimated timing) for each new track, follows the playback position, and shows the line being sung on
// every screen. Lookups wait for the track to stay current for LYRICS_FETCH_DEBOUNCE (a cache hit
// doesn't wait), and a skipped track's network work is cancelled. While a lookup is pending, and in a
// song's intro before its first line, the box shows the track's title and artist, small and dim.
// Fades out on pause, when lyrics are turned off, or when a song has no lyrics at all.
import AppKit

let LYRICS_TICK_INTERVAL: TimeInterval = 1.0 / 15
// Lines start this early so their entry animation lands on the beat
let LYRICS_LEAD: TimeInterval = 0.25
let LYRICS_POSITION_FRESHNESS: CFTimeInterval = 0.5
// Waits before asking LRCLIB again for the song that's still playing, after
// the provider's own quick retries all failed
let LYRICS_LOOKUP_RETRY_DELAYS: [TimeInterval] = [5, 10, 20, 30, 60]
// A track must stay current this long before its lyrics are looked up, so skipping
// through songs doesn't send a burst of requests
let LYRICS_FETCH_DEBOUNCE: TimeInterval = 0.6
// Set to 1 to log, once per change, which display condition holds the box empty
// (the numbered list in docs/LYRICS_LESSONS.md). Never logs lyric text.
let LYRICS_TRACE_ENV = "WALLPAPER_OVERLAY_TRACE_LYRICS"

// The lookup LyricsController needs; LyricsProvider is the real one
protocol LyricsLookup: AnyObject {
    func lyrics(trackID: String, artist: String, title: String, album: String, duration: TimeInterval?,
                completion: @escaping (LookupOutcome) -> Void)
    func cachedLyrics(trackID: String) -> LookupOutcome?
    func cancel(trackID: String)
}

extension LyricsProvider: LyricsLookup {}

func lyricsTraceFromEnvironment() -> ((String) -> Void)? {
    guard ProcessInfo.processInfo.environment[LYRICS_TRACE_ENV] == "1" else { return nil }
    return { NSLog("%@", $0) }
}

final class LyricsController {
    private let settings: Settings
    private let provider: LyricsLookup
    private let clock: PlaybackClock
    private let views: () -> [LyricsDisplay]
    private let accent: () -> NSColor
    private let trace: ((String) -> Void)?
    private let retryDelays: [TimeInterval]
    private var lastTrace: String?
    private var lyrics: TimedLyrics?
    private var trackID: String?
    private var currentTrack: SpotifyTrack?
    // True from the track change until the lookup answers (or gives up), retry waits included
    private var isLookupPending = false
    // Work that belongs to the current track's lookup; all of it is cancelled on a track change
    private var debounceTimer: DispatchWorkItem?
    private var retryTimer: DispatchWorkItem?
    private var requestedTrackID: String?
    // Bumped per track (and on stop) so stale lookups and retries are dropped,
    // even when the same song comes back
    private var lookupGeneration = 0
    // What the views currently show. `.blank` also means "draw again": it is reset whenever
    // the views' contents can no longer be trusted (hidden, replaced).
    private var shown: Shown = .blank
    private enum Shown: Equatable { case blank, placeholder, line(Int) }
    private var shownIndex: Int? {
        guard case .line(let index) = shown else { return nil }
        return index
    }
    // The views the box was last made visible on and shownIndex drawn on. A display
    // change makes OverlayController replace every view, and new ones start hidden
    // and empty, so shownIndex only means something for these same views.
    private var drawnViews: [ObjectIdentifier] = []
    private var isPlaying = false
    private var ticker: Timer?

    // `trace` gets one line per change of what the box shows and why; nil turns it off
    init(settings: Settings, provider: LyricsLookup, clock: PlaybackClock,
         views: @escaping () -> [LyricsDisplay], accent: @escaping () -> NSColor,
         trace: ((String) -> Void)? = lyricsTraceFromEnvironment(),
         retryDelays: [TimeInterval] = LYRICS_LOOKUP_RETRY_DELAYS) {
        self.settings = settings
        self.provider = provider
        self.clock = clock
        self.views = views
        self.accent = accent
        self.trace = trace
        self.retryDelays = retryDelays
        settings.observe { [weak self] key in
            guard key == .lyricsEnabled || key == .romajiEnabled else { return }
            self?.redrawCurrentLine()
        }
    }

    // `position` is the one the music app sent with this change, if it's fresh.
    // The old song's lyrics and line go first, then the clock moves, so no tick
    // can pair the previous song's lines with the new song's position.
    func trackChanged(_ track: SpotifyTrack, position: SpotifyPositionStamp?) {
        cancelLookupWork()
        currentTrack = track
        trackID = track.id
        lyrics = nil
        isLookupPending = false
        shown = .blank
        views().forEach { $0.clear() }
        if let position, CACurrentMediaTime() - position.at < LYRICS_POSITION_FRESHNESS {
            clock.resync(position: position.seconds + (CACurrentMediaTime() - position.at))
        } else {
            clock.reset()
        }
        lookupGeneration += 1
        beginLookup(for: track, generation: lookupGeneration)
        traceDecision()
    }

    // A cache hit is applied at once. Otherwise the lookup starts only once the track has stayed
    // current for LYRICS_FETCH_DEBOUNCE, so skipping through songs sends nothing and the song the
    // user lands on isn't queued behind (or throttled by) requests for songs they skipped.
    private func beginLookup(for track: SpotifyTrack, generation: Int) {
        if let cached = provider.cachedLyrics(trackID: track.id) {
            return receive(cached, for: track, generation: generation, attempt: 0)
        }
        isLookupPending = true
        trace?("wallpaper-overlay: lyrics trace debounced title=\(track.name) artist=\(track.artist) "
               + "wait=\(String(format: "%.1f", LYRICS_FETCH_DEBOUNCE))s")
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.lookupGeneration == generation else { return }
            self.debounceTimer = nil
            self.requestLyrics(for: track, generation: generation, attempt: 0)
        }
        debounceTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + LYRICS_FETCH_DEBOUNCE, execute: timer)
        refresh()
    }

    // Stops everything the previous track's lookup has in motion: the debounce wait, a retry wait
    // and the request on the wire. Late completions are also dropped by the generation check.
    private func cancelLookupWork() {
        var stopped: [String] = []
        if let timer = debounceTimer { timer.cancel(); debounceTimer = nil; stopped.append("debounce") }
        if let timer = retryTimer { timer.cancel(); retryTimer = nil; stopped.append("retry") }
        if let id = requestedTrackID {
            provider.cancel(trackID: id)
            requestedTrackID = nil
            stopped.append("request")
        }
        guard !stopped.isEmpty, let old = currentTrack else { return }
        trace?("wallpaper-overlay: lyrics trace cancelled title=\(old.name) artist=\(old.artist) "
               + "stopped=\(stopped.joined(separator: "+"))")
    }

    private func requestLyrics(for track: SpotifyTrack, generation: Int, attempt: Int) {
        requestedTrackID = track.id
        provider.lyrics(trackID: track.id, artist: track.artist, title: track.name, album: track.album,
                        duration: track.duration) { [weak self] outcome in
            guard let self, self.lookupGeneration == generation else { return }
            self.requestedTrackID = nil
            self.receive(outcome, for: track, generation: generation, attempt: attempt)
        }
    }

    // A transient failure (LRCLIB answers 503 often) asks again while the same
    // song is still on, instead of leaving it without lyrics until the next one
    private func receive(_ outcome: LookupOutcome, for track: SpotifyTrack, generation: Int, attempt: Int) {
        switch outcome {
        case .found(let found):
            if found.isEstimated {
                NSLog("wallpaper-overlay: lyrics %@ – %@: %d plain lines (estimated timing)",
                      track.artist, track.name, found.lines.count)
            } else {
                NSLog("wallpaper-overlay: lyrics %@ – %@: %d synced lines", track.artist, track.name, found.lines.count)
            }
            lyrics = found
            isLookupPending = false
        case .none:
            NSLog("wallpaper-overlay: lyrics %@ – %@: none", track.artist, track.name)
            isLookupPending = false
        case .failed:
            guard attempt < retryDelays.count else {
                NSLog("wallpaper-overlay: lyrics %@ – %@: unavailable, giving up", track.artist, track.name)
                isLookupPending = false
                return refresh()
            }
            let delay = retryDelays[attempt]
            NSLog("wallpaper-overlay: lyrics %@ – %@: unavailable, asking again in %.0fs",
                  track.artist, track.name, delay)
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.lookupGeneration == generation else { return }
                self.retryTimer = nil
                self.requestLyrics(for: track, generation: generation, attempt: attempt + 1)
            }
            retryTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
        }
        refresh()
    }

    func playStateChanged(_ playing: Bool) {
        isPlaying = playing
        clock.setPlaying(playing)
        updateVisibility()
    }

    // Playback stopped (not just paused): forget the song entirely. Safe to call
    // before or after the final playStateChanged(false), and more than once.
    func playbackEnded() {
        cancelLookupWork()
        trackID = nil
        currentTrack = nil
        isLookupPending = false
        lookupGeneration += 1
        lyrics = nil
        shown = .blank
        isPlaying = false
        clock.setPlaying(false)
        clock.reset()
        views().forEach { $0.clear() }
        updateVisibility()
    }

    func positionChanged(_ seconds: TimeInterval) {
        clock.resync(position: seconds)
    }

    // updateVisibility, and draw what changed now instead of at the next tick
    private func refresh() {
        updateVisibility()
        if ticker != nil { tick() }
    }

    private func updateVisibility() {
        defer { traceDecision() }
        let visible = isPlaying && settings.isLyricsEnabled && (lyrics != nil || isLookupPending)
        views().forEach { $0.setVisible(visible) }
        if visible {
            startTicking()
            return
        }
        stopTicking()
        // Once faded out, drop the line's layers; the next tick redraws on resume
        shown = .blank
        DispatchQueue.main.asyncAfter(deadline: .now() + LYRICS_FADE_DURATION) { [weak self] in
            guard let self, self.ticker == nil else { return }
            self.views().forEach { $0.removeLine() }
        }
    }

    private func startTicking() {
        guard ticker == nil else { return }
        // Scheduled on the main run loop, so the block really runs on the main actor
        let timer = Timer(timeInterval: LYRICS_TICK_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        tick()
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        defer { traceDecision() }
        adoptReplacedViews()
        guard let desired = desiredContent() else { return }
        guard desired != shown else { return }
        shown = desired
        switch desired {
        case .blank: views().forEach { $0.clear() }
        case .placeholder: showPlaceholder()
        case .line(let index):
            guard let lyrics, let position = clock.position() else { return }
            show(index: index, in: lyrics, position: position)
        }
    }

    // What the box should show now; nil while it can't be told (lyrics loaded, position unknown)
    private func desiredContent() -> Shown? {
        guard let lyrics else { return isLookupPending ? .placeholder : .blank }
        guard let position = clock.position() else { return nil }
        let at = position + LYRICS_LEAD
        // Only the start of the song: before the first sung line, not the gaps after it
        if let firstSung = lyrics.lines.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }),
           at < firstSung.start {
            return .placeholder
        }
        return lyrics.lineIndex(at: at).map(Shown.line) ?? .blank
    }

    // Ticks only run while the box should be visible: views that weren't there for the
    // last updateVisibility get the fade-in, and the current line is drawn again
    private func adoptReplacedViews() {
        let current = views()
        let ids = current.map(ObjectIdentifier.init)
        guard ids != drawnViews else { return }
        if !drawnViews.isEmpty { trace?("wallpaper-overlay: lyrics trace views replaced, redrawing on \(ids.count)") }
        drawnViews = ids
        current.forEach { $0.setVisible(true) }
        shown = .blank
    }

    private func redrawCurrentLine() {
        updateVisibility()
        guard let lyrics, let index = shownIndex, let position = clock.position() else { return }
        show(index: index, in: lyrics, position: position)
    }

    private func showPlaceholder() {
        guard let track = currentTrack else { return views().forEach { $0.clear() } }
        trace?("wallpaper-overlay: lyrics trace placeholder title=\(track.name) artist=\(track.artist) "
               + "reason=\(lyrics == nil ? "lookup-pending" : "intro")")
        views().forEach { $0.showPlaceholder(title: track.name, artist: track.artist) }
    }

    private func show(index: Int, in lyrics: TimedLyrics, position: TimeInterval) {
        let line = lyrics.lines[index]
        let romaji = settings.isRomajiEnabled ? LyricsProvider.romaji(for: line.text) : nil
        let remaining = max(0.5, line.end - position)
        let reducedMotion = ProcessInfo.processInfo.isLowPowerModeEnabled
        let color = accent()
        views().forEach {
            $0.show(text: line.text, romaji: romaji, duration: remaining, accent: color, reducedMotion: reducedMotion,
                    isEstimated: lyrics.isEstimated)
        }
    }

    // MARK: Trace

    // The first display condition that fails (numbered as in docs/LYRICS_LESSONS.md),
    // or "shown". Logged only when it, the line index, visibility or shownIndex changes.
    private func traceDecision() {
        guard let trace else { return }
        let position = clock.position()
        let index = position.flatMap { lyrics?.lineIndex(at: $0 + LYRICS_LEAD) }
        let isVisible = ticker != nil
        let decision = "\(failedCondition(position: position, index: index, isVisible: isVisible)) index=\(describe(index)) "
            + "visible=\(isVisible) shownIndex=\(describe(shownIndex))"
        guard decision != lastTrace else { return }
        lastTrace = decision
        let at = position.map { String(format: "%.2f", $0) } ?? "nil"
        trace("wallpaper-overlay: lyrics trace \(decision) position=\(at)")
    }

    private func failedCondition(position: TimeInterval?, index: Int?, isVisible: Bool) -> String {
        guard trackID != nil else { return "1-track-unknown" }
        guard let lyrics else { return isLookupPending ? "2-lookup-pending" : "2-no-lyrics" }
        guard isPlaying, settings.isLyricsEnabled else { return "3-not-playing-or-off" }
        guard position != nil else { return "4-position-unknown" }
        guard let index, !lyrics.lines[index].text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "5-between-lines"
        }
        guard isVisible, shownIndex == index, drawnViews == views().map(ObjectIdentifier.init) else {
            return "6-not-drawn"
        }
        return "shown"
    }

    private func describe(_ index: Int?) -> String { index.map(String.init) ?? "nil" }
}
