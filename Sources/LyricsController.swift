// Keeps the lyric box in step with the music app: fetches lyrics (synced, or plain with
// estimated timing) for each new track, follows the playback position, and shows the line being sung on
// every screen. Fades out on pause, when lyrics are turned off, or when a
// song has no lyrics at all.
import AppKit

let LYRICS_TICK_INTERVAL: TimeInterval = 1.0 / 15
// Lines start this early so their entry animation lands on the beat
let LYRICS_LEAD: TimeInterval = 0.25
let LYRICS_POSITION_FRESHNESS: CFTimeInterval = 0.5
// Waits before asking LRCLIB again for the song that's still playing, after
// the provider's own quick retries all failed
let LYRICS_LOOKUP_RETRY_DELAYS: [TimeInterval] = [5, 10, 20, 30, 60]
// Set to 1 to log, once per change, which display condition holds the box empty
// (the numbered list in docs/LYRICS_LESSONS.md). Never logs lyric text.
let LYRICS_TRACE_ENV = "WALLPAPER_OVERLAY_TRACE_LYRICS"

// The lookup LyricsController needs; LyricsProvider is the real one
protocol LyricsLookup: AnyObject {
    func lyrics(trackID: String, artist: String, title: String, album: String, duration: TimeInterval?,
                completion: @escaping (LookupOutcome) -> Void)
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
    private var lastTrace: String?
    private var lyrics: TimedLyrics?
    private var trackID: String?
    // Bumped per track (and on stop) so stale lookups and retries are dropped,
    // even when the same song comes back
    private var lookupGeneration = 0
    private var shownIndex: Int?
    // The views the box was last made visible on and shownIndex drawn on. A display
    // change makes OverlayController replace every view, and new ones start hidden
    // and empty, so shownIndex only means something for these same views.
    private var drawnViews: [ObjectIdentifier] = []
    private var isPlaying = false
    private var ticker: Timer?

    // `trace` gets one line per change of what the box shows and why; nil turns it off
    init(settings: Settings, provider: LyricsLookup, clock: PlaybackClock,
         views: @escaping () -> [LyricsDisplay], accent: @escaping () -> NSColor,
         trace: ((String) -> Void)? = lyricsTraceFromEnvironment()) {
        self.settings = settings
        self.provider = provider
        self.clock = clock
        self.views = views
        self.accent = accent
        self.trace = trace
        settings.observe { [weak self] key in
            guard key == .lyricsEnabled || key == .romajiEnabled else { return }
            self?.redrawCurrentLine()
        }
    }

    // `position` is the one the music app sent with this change, if it's fresh.
    // The old song's lyrics and line go first, then the clock moves, so no tick
    // can pair the previous song's lines with the new song's position.
    func trackChanged(_ track: SpotifyTrack, position: SpotifyPositionStamp?) {
        trackID = track.id
        lyrics = nil
        shownIndex = nil
        views().forEach { $0.clear() }
        if let position, CACurrentMediaTime() - position.at < LYRICS_POSITION_FRESHNESS {
            clock.resync(position: position.seconds + (CACurrentMediaTime() - position.at))
        } else {
            clock.reset()
        }
        lookupGeneration += 1
        requestLyrics(for: track, generation: lookupGeneration, attempt: 0)
        traceDecision()
    }

    // A transient failure (LRCLIB answers 503 often) asks again while the same
    // song is still on, instead of leaving it without lyrics until the next one
    private func requestLyrics(for track: SpotifyTrack, generation: Int, attempt: Int) {
        provider.lyrics(trackID: track.id, artist: track.artist, title: track.name, album: track.album,
                        duration: track.duration) { [weak self] outcome in
            guard let self, self.lookupGeneration == generation else { return }
            switch outcome {
            case .found(let found):
                if found.isEstimated {
                    NSLog("wallpaper-overlay: lyrics %@ – %@: %d plain lines (estimated timing)",
                          track.artist, track.name, found.lines.count)
                } else {
                    NSLog("wallpaper-overlay: lyrics %@ – %@: %d synced lines", track.artist, track.name, found.lines.count)
                }
                self.lyrics = found
                self.updateVisibility()
            case .none:
                NSLog("wallpaper-overlay: lyrics %@ – %@: none", track.artist, track.name)
                self.updateVisibility()
            case .failed:
                guard attempt < LYRICS_LOOKUP_RETRY_DELAYS.count else {
                    NSLog("wallpaper-overlay: lyrics %@ – %@: unavailable, giving up", track.artist, track.name)
                    return self.updateVisibility()
                }
                let delay = LYRICS_LOOKUP_RETRY_DELAYS[attempt]
                NSLog("wallpaper-overlay: lyrics %@ – %@: unavailable, asking again in %.0fs",
                      track.artist, track.name, delay)
                self.updateVisibility()
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.lookupGeneration == generation else { return }
                    self.requestLyrics(for: track, generation: generation, attempt: attempt + 1)
                }
            }
        }
    }

    func playStateChanged(_ playing: Bool) {
        isPlaying = playing
        clock.setPlaying(playing)
        updateVisibility()
    }

    // Playback stopped (not just paused): forget the song entirely. Safe to call
    // before or after the final playStateChanged(false), and more than once.
    func playbackEnded() {
        trackID = nil
        lookupGeneration += 1
        lyrics = nil
        shownIndex = nil
        isPlaying = false
        clock.setPlaying(false)
        clock.reset()
        views().forEach { $0.clear() }
        updateVisibility()
    }

    func positionChanged(_ seconds: TimeInterval) {
        clock.resync(position: seconds)
    }

    private func updateVisibility() {
        defer { traceDecision() }
        let visible = isPlaying && settings.isLyricsEnabled && lyrics != nil
        views().forEach { $0.setVisible(visible) }
        if visible {
            startTicking()
            return
        }
        stopTicking()
        // Once faded out, drop the line's layers; the next tick redraws on resume
        shownIndex = nil
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
        guard let lyrics, let position = clock.position() else { return }
        let index = lyrics.lineIndex(at: position + LYRICS_LEAD)
        guard index != shownIndex else { return }
        shownIndex = index
        show(index: index, in: lyrics, position: position)
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
        shownIndex = nil
    }

    private func redrawCurrentLine() {
        updateVisibility()
        guard let lyrics, let index = shownIndex, let position = clock.position() else { return }
        show(index: index, in: lyrics, position: position)
    }

    private func show(index: Int?, in lyrics: TimedLyrics, position: TimeInterval) {
        guard let index else {
            views().forEach { $0.clear() }
            return
        }
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
        guard let lyrics else { return "2-no-lyrics" }
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
