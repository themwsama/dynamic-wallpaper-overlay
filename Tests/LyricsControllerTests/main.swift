// End-to-end replay of Spotify event sequences through the real LyricsController,
// PlaybackClock, MusicSession and SpotifyWatcher. Faked: Spotify's notifications (on a
// private center), its true position and the poll answers (on a fake clock), the lyrics
// lookup, and the views, which record what they show. Lyrics are invented.
//
// The invariant every check asserts: while Spotify plays and its true position (plus
// LYRICS_LEAD) is inside a non-empty line of the current song's loaded lyrics, every
// view is visible and shows that line, within one tick.
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let extra = ok ? "" : "  [\(detail())]"
    print("\(ok ? "PASS" : "FAIL") \(name)\(extra)")
    if !ok { failures += 1 }
}

func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// Two ticks of real time, so "within one tick" holds whatever the timer phase
let ONE_TICK = LYRICS_TICK_INTERVAL * 2
// Longer than the box's fade, so any delayed cleanup has run
let AFTER_FADE = LYRICS_FADE_DURATION + 0.2

// MARK: Fakes

final class FakeView: LyricsDisplay {
    private(set) var isVisible = false  // a new LyricsView starts at opacity 0
    private(set) var text: String?
    func setVisible(_ visible: Bool) { isVisible = visible }
    func clear() { text = nil }
    func removeLine() { text = nil }
    func show(text: String, romaji: String?, duration: TimeInterval, accent: NSColor, reducedMotion: Bool,
              isEstimated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        self.text = trimmed.isEmpty ? nil : trimmed
    }
}

// Spotify's real state on a fake clock. The clock's poll reads it on the script queue.
final class FakeSpotify: SpotifyPositionSource, @unchecked Sendable {
    let queue = DispatchQueue(label: "test.spotify-script")
    private let lock = NSLock()
    private var time: CFTimeInterval = 1000
    private var playing = false
    private var anchorPosition: TimeInterval = 0
    private var anchorTime: CFTimeInterval = 1000
    private var pollError: Int?

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var now: CFTimeInterval { locked { time } }
    var isPlaying: Bool { locked { playing } }
    var position: TimeInterval { locked { truePosition() } }
    private func truePosition() -> TimeInterval { playing ? anchorPosition + (time - anchorTime) : anchorPosition }

    func advance(_ seconds: TimeInterval) { locked { time += seconds } }
    func set(playing: Bool? = nil, position: TimeInterval? = nil) {
        locked {
            let current = truePosition()
            anchorPosition = position ?? current
            anchorTime = time
            if let playing { self.playing = playing }
        }
    }
    func failPolls(_ errorNumber: Int?) { locked { pollError = errorNumber } }

    func currentPosition() -> TimeInterval? { locked { pollError == nil ? truePosition() : nil } }
    var lastErrorNumber: Int? { locked { pollError } }
}

// Answers from a table; a held track's answer waits until `release`
final class FakeLookup: LyricsLookup {
    var answers: [String: TimedLyrics] = [:]
    var held: Set<String> = []
    private var pending: [(String, (LookupOutcome) -> Void)] = []
    private(set) var requests: [String] = []

    func lyrics(trackID: String, artist: String, title: String, album: String, duration: TimeInterval?,
                completion: @escaping (LookupOutcome) -> Void) {
        requests.append(trackID)
        if held.contains(trackID) { return pending.append((trackID, completion)) }
        completion(answers[trackID].map(LookupOutcome.found) ?? .none)
    }

    func release(_ trackID: String) {
        held.remove(trackID)
        let ready = pending.filter { $0.0 == trackID }
        pending.removeAll { $0.0 == trackID }
        ready.forEach { $0.1(answers[trackID].map(LookupOutcome.found) ?? .none) }
    }
}

// MARK: Invented songs

func song(_ id: String, duration: TimeInterval = 200) -> SpotifyTrack {
    SpotifyTrack(id: SPOTIFY_TRACK_ID_PREFIX + id, name: "Song \(id)", artist: "Lantern Choir", album: "Night Songs",
                 duration: duration)
}

// Intro until 4 s, lines every 4 s, an instrumental gap at 20-28 s, more lines to 48 s
func syncedLyrics(_ tag: String) -> TimedLyrics {
    var lines: [LyricLine] = []
    for i in 0..<4 { lines.append(LyricLine(start: 4 + Double(i) * 4, end: 8 + Double(i) * 4, text: "\(tag) line \(i + 1)", words: nil)) }
    lines.append(LyricLine(start: 20, end: 28, text: "", words: nil))
    for i in 0..<5 { lines.append(LyricLine(start: 28 + Double(i) * 4, end: 32 + Double(i) * 4, text: "\(tag) verse \(i + 1)", words: nil)) }
    return TimedLyrics(lines: lines)
}

// MARK: Harness, wired the way OverlayController wires the real thing

final class Harness {
    let center = NotificationCenter()
    let spotify = FakeSpotify()
    let lookup = FakeLookup()
    let settings: Settings
    let clock: PlaybackClock
    let session: MusicSession
    var views: [FakeView] = [FakeView(), FakeView()]  // two screens
    var controller: LyricsController!
    var current: SpotifyTrack?
    var traces: [String] = []

    init(suite: UserDefaults) {
        settings = Settings(defaults: suite)
        let spotify = self.spotify
        clock = PlaybackClock(bundleID: "com.example.player", source: spotify, now: { spotify.now },
                              isAppRunning: { true }, log: { _ in })
        session = MusicSession(
            notificationCenter: center, runScript: { _ in (nil, nil) },
            makeTap: { SpotifyAudioTap(buildOverride: {}) }, schedule: { _, _ in },
            isAppRunning: { _ in false }, workspaceCenter: NotificationCenter())
        controller = LyricsController(
            settings: settings, provider: lookup, clock: clock, views: { [unowned self] in self.views },
            accent: { .white }, trace: { [unowned self] in self.traces.append($0) })
        session.onTrack = { [unowned self] track in self.controller.trackChanged(track, position: self.session.lastPosition) }
        session.onPlayState = { [unowned self] playing in self.controller.playStateChanged(playing) }
        session.onPosition = { [unowned self] seconds in self.controller.positionChanged(seconds) }
        session.onEnded = { [unowned self] in self.controller.playbackEnded() }
        session.start()
        spin(0.05)  // the launch bootstrap reports nothing
    }

    // Spotify's broadcast. Every one observed carries "Playback Position".
    func broadcast(includePosition: Bool = true) {
        var info: [AnyHashable: Any] = ["Player State": spotify.isPlaying ? "Playing" : "Paused"]
        if let track = current {
            info["Track ID"] = track.id
            info["Name"] = track.name
            info["Artist"] = track.artist
            info["Album"] = track.album
            info["Duration"] = (track.duration ?? 0) * 1000
        }
        if includePosition { info["Playback Position"] = spotify.position }
        center.post(name: SPOTIFY_NOTIFICATION, object: nil, userInfo: info)
    }

    func play(_ track: SpotifyTrack, at position: TimeInterval = 0, includePosition: Bool = true) {
        current = track
        spotify.set(playing: true, position: position)
        broadcast(includePosition: includePosition)
    }
    func pause() { spotify.set(playing: false); broadcast() }
    func resume() { spotify.set(playing: true); broadcast() }
    // Spotify reports a seek with one broadcast in the current state
    func seek(to position: TimeInterval) { spotify.set(position: position); broadcast() }
    func poll() {
        var done = false
        clock.pollOnce { done = true }
        let end = Date().addingTimeInterval(2)
        while !done && Date() < end { spin(0.005) }
    }
    // A display change: OverlayController.rebuild() replaces every window and view
    func rebuildWindows() { views = [FakeView(), FakeView()] }

    // What the box must show right now; nil when it may be empty
    func expectedLine() -> String? {
        guard spotify.isPlaying, settings.isLyricsEnabled, let track = current,
              let lyrics = lookup.answers[track.id], !lookup.held.contains(track.id),
              let index = lyrics.lineIndex(at: spotify.position + LYRICS_LEAD) else { return nil }
        let text = lyrics.lines[index].text
        return text.isEmpty ? nil : text
    }

    func describeViews() -> String {
        views.map { "visible=\($0.isVisible) text=\($0.text ?? "nil")" }.joined(separator: "; ")
            + " truePosition=\(String(format: "%.2f", spotify.position)) clock=\(clock.position().map { String(format: "%.2f", $0) } ?? "nil")"
            + " lastTrace=\(traces.last ?? "none")"
    }

    // The invariant, one tick after whatever just happened
    func expectInvariant(_ name: String) {
        spin(ONE_TICK)
        if let line = expectedLine() {
            let ok = views.allSatisfy { $0.isVisible && $0.text == line }
            check("\(name): shows \"\(line)\"", ok, describeViews())
        } else if spotify.isPlaying {
            let ok = views.allSatisfy { $0.text == nil || !$0.isVisible }
            check("\(name): box empty", ok, describeViews())
        } else {
            check("\(name): box hidden", views.allSatisfy { !$0.isVisible }, describeViews())
        }
    }

    // Plays on for `seconds`, checking the invariant every second
    func playOn(_ seconds: Int, _ name: String) {
        for _ in 0..<seconds {
            spotify.advance(1)
            expectInvariant("\(name) @\(String(format: "%.0f", spotify.position))s")
        }
    }
}

let suiteName = CommandLine.arguments.dropFirst().first ?? "wallpaper-overlay-lyrics-test-\(UUID().uuidString)"
guard let suite = UserDefaults(suiteName: suiteName) else { fatalError("no defaults suite") }

func scenario(_ title: String, _ body: (Harness) -> Void) {
    print("-- \(title)")
    suite.removePersistentDomain(forName: suiteName)
    let h = Harness(suite: suite)
    body(h)
    h.session.watcher.stop()
}

let songA = song("aaaa"), songB = song("bbbb"), songC = song("cccc"), songP = song("pppp")

scenario("normal play") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA)
    h.expectInvariant("start")
    h.playOn(36, "A")
}

scenario("seek forward and back") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.expectInvariant("start mid-line")
    h.seek(to: 33)
    h.expectInvariant("seek forward")
    h.seek(to: 10)
    h.expectInvariant("seek back")
    h.seek(to: 10.5)  // within the same line
    h.expectInvariant("seek inside the line")
    h.playOn(3, "after seeks")
}

scenario("seek without a broadcast, the poll finds it") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.expectInvariant("start")
    h.spotify.set(position: 30)
    h.poll()
    h.expectInvariant("after the poll")
}

scenario("pause and resume") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.expectInvariant("playing")
    h.pause()
    h.expectInvariant("paused")
    spin(AFTER_FADE)
    h.spotify.advance(30)  // time passes, position doesn't
    h.resume()
    h.expectInvariant("resumed")
    h.playOn(3, "after resume")
}

scenario("pause/resume pair faster than the fade") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.expectInvariant("playing")
    h.pause()
    spin(0.1)
    h.resume()
    h.expectInvariant("resumed at once")
    spin(AFTER_FADE)
    h.expectInvariant("after the old fade's cleanup")
}

scenario("resume after a long pause") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 9)
    h.pause()
    spin(AFTER_FADE)
    h.spotify.advance(3600)
    h.resume()
    h.expectInvariant("resumed")
    h.playOn(5, "after the long pause")
}

scenario("skip") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.lookup.answers[songB.id] = syncedLyrics("B")
    h.play(songA, at: 9)
    h.expectInvariant("A")
    h.play(songB, at: 0)
    h.expectInvariant("B intro")
    h.playOn(6, "B")
}

scenario("skip to a song without lyrics, then one with") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.lookup.answers[songC.id] = syncedLyrics("C")
    h.play(songA, at: 9)
    h.play(songB, at: 0)
    h.expectInvariant("B has none")
    h.spotify.advance(0.2)
    h.play(songC, at: 6)
    h.expectInvariant("C right after B")
    spin(AFTER_FADE)
    h.expectInvariant("C after B's fade cleanup")
}

scenario("broadcast without a position, poll works") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 12, includePosition: false)
    h.poll()
    h.expectInvariant("after the first poll")
    h.playOn(3, "A")
}

scenario("polls denied, broadcasts carry the position") { h in
    h.spotify.failPolls(APPLESCRIPT_NOT_AUTHORIZED)
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    for _ in 0..<4 { h.poll() }
    h.expectInvariant("start")
    h.playOn(4, "A")
    h.seek(to: 30)
    h.expectInvariant("seek")
}

scenario("track change while fetching") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.lookup.answers[songB.id] = syncedLyrics("B")
    h.lookup.answers[songC.id] = syncedLyrics("C")
    h.lookup.held = [songB.id]
    h.play(songA, at: 9)
    h.play(songB, at: 0)
    h.spotify.advance(5)
    h.expectInvariant("B still fetching")
    h.play(songC, at: 5)
    h.expectInvariant("C")
    h.lookup.release(songB.id)  // late answer for the song that's gone
    h.expectInvariant("C after B's late answer")
    h.playOn(4, "C")
}

scenario("estimated (plain) lyrics") { h in
    let plain = (1...12).map { "Plain row \($0) of the invented song" }.joined(separator: "\n")
    guard let estimated = LyricsProvider.estimateTiming(plain: plain, duration: 120) else {
        return check("estimated lyrics built", false)
    }
    h.lookup.answers[songP.id] = estimated
    h.play(songP, at: 0)
    h.playOn(30, "P")
}

scenario("lyrics tile off and on") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.settings.isLyricsEnabled = false
    h.expectInvariant("off")
    h.settings.isLyricsEnabled = true
    h.expectInvariant("on again at once")
    spin(AFTER_FADE)
    h.expectInvariant("after the fade cleanup")
}

scenario("windows rebuilt while playing (display change)") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.expectInvariant("before")
    h.rebuildWindows()
    h.expectInvariant("same line after the rebuild")
    h.playOn(6, "after the rebuild")
    check("trace logged the replaced views", h.traces.contains { $0.contains("views replaced") })
}

scenario("windows rebuilt while paused") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    h.pause()
    spin(AFTER_FADE)
    h.rebuildWindows()
    h.resume()
    h.expectInvariant("resumed after the rebuild")
}

scenario("trace names the failing condition, without lyric text") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 0)
    h.expectInvariant("intro")
    h.spotify.advance(5)
    h.expectInvariant("first line")
    h.pause()
    h.expectInvariant("paused")
    check("trace logged the intro as between lines", h.traces.contains { $0.contains("5-between-lines") })
    check("trace logged the line as shown", h.traces.contains { $0.contains("shown index=0") })
    check("trace logged the pause", h.traces.contains { $0.contains("3-not-playing-or-off") })
    check("trace never carries lyric text", !h.traces.contains { $0.contains(" line ") || $0.contains("verse") })
    let before = h.traces.count
    spin(0.5)
    check("trace is quiet while nothing changes", h.traces.count == before)
}

suite.removePersistentDomain(forName: suiteName)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
