// Keeps the lyric box in step with Spotify: fetches synced lyrics for each new
// track, follows the playback position, and shows the line being sung on
// every screen. Fades out on pause, when lyrics are turned off, or when a
// song has no synced lyrics.
import AppKit

let LYRICS_TICK_INTERVAL: TimeInterval = 1.0 / 15
// Lines start this early so their entry animation lands on the beat
let LYRICS_LEAD: TimeInterval = 0.25
let LYRICS_POSITION_FRESHNESS: CFTimeInterval = 0.5
// Waits before asking LRCLIB again for the song that's still playing, after
// the provider's own quick retries all failed
let LYRICS_LOOKUP_RETRY_DELAYS: [TimeInterval] = [5, 10, 20, 30, 60]

final class LyricsController {
    private let settings: Settings
    private let provider: LyricsProvider
    private let clock: PlaybackClock
    private let views: () -> [LyricsView]
    private let accent: () -> NSColor
    private var lyrics: TimedLyrics?
    private var trackID: String?
    // Bumped per track (and on stop) so stale lookups and retries are dropped,
    // even when the same song comes back
    private var lookupGeneration = 0
    private var shownIndex: Int?
    private var isPlaying = false
    private var ticker: Timer?

    init(settings: Settings, provider: LyricsProvider, clock: PlaybackClock,
         views: @escaping () -> [LyricsView], accent: @escaping () -> NSColor) {
        self.settings = settings
        self.provider = provider
        self.clock = clock
        self.views = views
        self.accent = accent
        settings.observe { [weak self] key in
            guard key == .lyricsEnabled || key == .romajiEnabled else { return }
            self?.redrawCurrentLine()
        }
    }

    // `position` is the one Spotify sent with this change, if it's fresh
    func trackChanged(_ track: SpotifyTrack, position: (seconds: TimeInterval, at: CFTimeInterval)?) {
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
    }

    // A transient failure (LRCLIB answers 503 often) asks again while the same
    // song is still on, instead of leaving it without lyrics until the next one
    private func requestLyrics(for track: SpotifyTrack, generation: Int, attempt: Int) {
        provider.lyrics(trackID: track.id, artist: track.artist, title: track.name, album: track.album,
                        duration: track.duration) { [weak self] outcome in
            guard let self, self.lookupGeneration == generation else { return }
            switch outcome {
            case .found(let found):
                NSLog("wallpaper-overlay: lyrics %@ – %@: %d synced lines", track.artist, track.name, found.lines.count)
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

    // Spotify stopped (not just paused): forget the song entirely
    func playbackEnded() {
        trackID = nil
        lookupGeneration += 1
        lyrics = nil
        clock.reset()
        updateVisibility()
    }

    func positionChanged(_ seconds: TimeInterval) {
        clock.resync(position: seconds)
    }

    private func updateVisibility() {
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
        let timer = Timer(timeInterval: LYRICS_TICK_INTERVAL, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        tick()
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let lyrics, let position = clock.position() else { return }
        let index = lyrics.lineIndex(at: position + LYRICS_LEAD)
        guard index != shownIndex else { return }
        shownIndex = index
        show(index: index, in: lyrics, position: position)
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
            $0.show(text: line.text, romaji: romaji, duration: remaining, accent: color, reducedMotion: reducedMotion)
        }
    }
}

// Spotify's broadcast only arrives on changes, so ask once at launch what's
// already playing and replay it as if Spotify had just announced it.
// Only runs when Spotify is open, since the script would otherwise launch it.
func fetchSpotifyNowPlaying(completion: @escaping ([AnyHashable: Any]?) -> Void) {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: SPOTIFY_BUNDLE_ID).isEmpty else {
        NSLog("wallpaper-overlay: Spotify isn't running at launch; waiting for its first broadcast")
        completion(nil)
        return
    }
    DispatchQueue.global(qos: .utility).async {
        let source = """
        tell application "Spotify"
            set t to current track
            return (player state as string) & linefeed & (id of t) & linefeed & (name of t) & linefeed & ¬
                (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position)
        end tell
        """
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        let fields = output?.components(separatedBy: "\n") ?? []
        // Typed on purpose: inside the [AnyHashable: Any] literal `capitalized`
        // resolved to a function and `??` to an Optional, so the state never read
        // as "Playing" and the numbers never as NSNumber
        let state: String = fields.first?.capitalized ?? ""
        func number(_ index: Int) -> Double {
            guard index < fields.count else { return 0 }
            return Double(fields[index].replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        let info: [AnyHashable: Any]? = fields.count == 7 ? [
            "Player State": state,
            "Track ID": fields[1],
            "Name": fields[2],
            "Artist": fields[3],
            "Album": fields[4],
            "Duration": number(5),
            "Playback Position": number(6),
        ] : nil
        if info == nil {
            NSLog("wallpaper-overlay: couldn't read Spotify's current track: %@", error?.description ?? "no output")
        }
        DispatchQueue.main.async { completion(info) }
    }
}
