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
    // "title|artist" while the track-name placeholder is up
    private(set) var placeholder: String?
    func setVisible(_ visible: Bool) { isVisible = visible }
    func clear() { text = nil; placeholder = nil }
    func removeLine() { text = nil; placeholder = nil }
    func showPlaceholder(title: String, artist: String) {
        text = nil
        placeholder = "\(title)|\(artist)"
    }
    func show(text: String, romaji: String?, duration: TimeInterval, accent: NSColor, reducedMotion: Bool,
              isEstimated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        self.text = trimmed.isEmpty ? nil : trimmed
        placeholder = nil
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

// Answers from a table; a held track's answer waits until `release`. With `usesCache` the table
// doubles as the provider's disk cache (every unheld track is a hit, a track without an answer a
// cached "none"); tests of the network path turn it off. `failures[id]` makes the first N network
// requests for that track fail transiently.
final class FakeLookup: LyricsLookup {
    var answers: [String: TimedLyrics] = [:]
    var held: Set<String> = []
    var usesCache = true
    var failures: [String: Int] = [:]
    // A real provider never completes a cancelled request; flip to model one that answers late
    var honorsCancel = true
    private var pending: [(String, (LookupOutcome) -> Void)] = []
    private(set) var requests: [String] = []
    private(set) var cancelled: [String] = []

    func cachedLyrics(trackID: String) -> LookupOutcome? {
        guard usesCache, !held.contains(trackID) else { return nil }
        return answers[trackID].map(LookupOutcome.found) ?? LookupOutcome.none
    }

    func cancel(trackID: String) {
        cancelled.append(trackID)
        if honorsCancel { pending.removeAll { $0.0 == trackID } }
    }

    func lyrics(trackID: String, artist: String, title: String, album: String, duration: TimeInterval?,
                completion: @escaping (LookupOutcome) -> Void) {
        requests.append(trackID)
        if let left = failures[trackID], left > 0 {
            failures[trackID] = left - 1
            return completion(.failed)
        }
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

// Short enough to wait out in a test; the real ones are 5 s and up
let TEST_RETRY_DELAYS: [TimeInterval] = [0.8, 1.0]

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
            accent: { .white }, trace: { [unowned self] in self.traces.append($0) }, retryDelays: TEST_RETRY_DELAYS)
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


// MARK: Debounce, cancellation, placeholder

// Polls the run loop until the condition holds; false on timeout
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { spin(0.01) }
    return condition()
}

func spamSong(_ n: Int) -> SpotifyTrack { song("spam\(n)") }
let PLACEHOLDER_SLACK = 0.15  // scheduling jitter allowed on top of the stated bounds

scenario("skip spam: 8 quick skips, the 9th stays") { h in
    h.lookup.usesCache = false
    for n in 1...9 { h.lookup.answers[spamSong(n).id] = syncedLyrics("S\(n)") }
    h.lookup.held = [spamSong(9).id]
    for n in 1...8 {
        h.play(spamSong(n), at: 0)
        h.spotify.advance(0.3)
        spin(0.3)
    }
    check("skip spam: no lookup while skipping", h.lookup.requests.isEmpty, "\(h.lookup.requests)")
    check("skip spam: no lookup was cancelled that never started", h.lookup.cancelled.isEmpty, "\(h.lookup.cancelled)")
    let landed = Date()
    h.play(spamSong(9), at: 0)
    spin(ONE_TICK)
    check("skip spam: placeholder shows while the lookup waits",
          h.views.allSatisfy { $0.isVisible && $0.placeholder == "Song spam9|Lantern Choir" }, h.describeViews())
    spin(LYRICS_FETCH_DEBOUNCE / 2)
    check("skip spam: still nothing mid-debounce", h.lookup.requests.isEmpty, "\(h.lookup.requests)")
    check("skip spam: lookup starts after the debounce", waitUntil { h.lookup.requests.count == 1 })
    check("skip spam: that lookup is for the 9th track only", h.lookup.requests == [spamSong(9).id], "\(h.lookup.requests)")
    check("skip spam: waited at least the debounce", Date().timeIntervalSince(landed) >= LYRICS_FETCH_DEBOUNCE - 0.05)
    check("skip spam: placeholder stays while the lookup is in flight",
          h.views.allSatisfy { $0.placeholder == "Song spam9|Lantern Choir" }, h.describeViews())
    // The network answers 0.2 s later; the song is already past its first line
    let fetchTime = 0.2
    spin(fetchTime)
    h.lookup.release(spamSong(9).id)
    h.spotify.advance(4.0)
    let shown = waitUntil { h.views.allSatisfy { $0.text == "S9 line 1" } }
    let elapsed = Date().timeIntervalSince(landed)
    check("skip spam: first line shows", shown, h.describeViews())
    check("skip spam: first line within debounce + fetch + 1 tick",
          elapsed <= LYRICS_FETCH_DEBOUNCE + fetchTime + ONE_TICK + PLACEHOLDER_SLACK + 0.1, String(format: "%.2f s", elapsed))
    check("skip spam: no stray lookup afterwards", h.lookup.requests == [spamSong(9).id], "\(h.lookup.requests)")
    check("skip spam: trace has debounced", h.traces.contains { $0.contains("debounced") })
    check("skip spam: trace has cancelled", h.traces.contains { $0.contains("cancelled") })
    check("skip spam: trace has placeholder", h.traces.contains { $0.contains("placeholder") })
    check("skip spam: trace names titles, never lyric text",
          h.traces.contains { $0.contains("Song spam9") } && !h.traces.contains { $0.contains(" line ") || $0.contains("verse") })
}

scenario("cache hit applies at once, without the debounce") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 5)
    spin(ONE_TICK)
    check("cache hit: line shown within a tick", h.views.allSatisfy { $0.isVisible && $0.text == "A line 1" }, h.describeViews())
    check("cache hit: nothing waited on", LYRICS_FETCH_DEBOUNCE > ONE_TICK * 2)
    check("cache hit: no network lookup", h.lookup.requests.isEmpty, "\(h.lookup.requests)")
    spin(LYRICS_FETCH_DEBOUNCE + 0.1)
    check("cache hit: still no network lookup after the debounce", h.lookup.requests.isEmpty, "\(h.lookup.requests)")
    check("cache hit: no placeholder anywhere", !h.traces.contains { $0.contains("placeholder") }, "\(h.traces)")
}

scenario("cached 'none' needs no lookup and no placeholder") { h in
    h.play(songB, at: 0)  // no answer: cached none
    spin(LYRICS_FETCH_DEBOUNCE + 0.2)
    check("cached none: no network lookup", h.lookup.requests.isEmpty, "\(h.lookup.requests)")
    check("cached none: box empty, no placeholder", h.views.allSatisfy { $0.text == nil && $0.placeholder == nil }, h.describeViews())
}

scenario("retry in flight when a newer track arrives") { h in
    h.lookup.usesCache = false
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.lookup.answers[songB.id] = syncedLyrics("B")
    h.lookup.failures[songA.id] = 1
    h.play(songA, at: 0)
    check("retry: A looked up once after the debounce", waitUntil { h.lookup.requests == [songA.id] }, "\(h.lookup.requests)")
    spin(0.1)  // A failed; its retry timer is now waiting
    check("retry: placeholder stays while the retry waits", h.views.allSatisfy { $0.placeholder == "Song aaaa|Lantern Choir" }, h.describeViews())
    h.play(songB, at: 0)
    spin(TEST_RETRY_DELAYS[0] + 0.4)  // past the moment A's retry would have fired
    check("retry: A's retry never fires", !h.lookup.requests.dropFirst().contains(songA.id), "\(h.lookup.requests)")
    check("retry: B looked up after its own debounce", waitUntil { h.lookup.requests.contains(songB.id) }, "\(h.lookup.requests)")
    h.spotify.advance(4.2)
    check("retry: only B's line is ever shown", waitUntil { h.views.allSatisfy { $0.text == "B line 1" } }, h.describeViews())
    check("retry: exactly A once and B once", h.lookup.requests == [songA.id, songB.id], "\(h.lookup.requests)")
}

scenario("request in flight when a newer track arrives") { h in
    h.lookup.usesCache = false
    h.lookup.honorsCancel = false  // even a provider that answers late must not leak into the new track
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.lookup.answers[songB.id] = syncedLyrics("B")
    h.lookup.held = [songA.id]
    h.play(songA, at: 0)
    check("in flight: A's request is out", waitUntil { h.lookup.requests == [songA.id] }, "\(h.lookup.requests)")
    h.play(songB, at: 0)
    check("in flight: A's request was cancelled", h.lookup.cancelled == [songA.id], "\(h.lookup.cancelled)")
    check("in flight: trace has cancelled", h.traces.contains { $0.contains("cancelled") })
    check("in flight: B looked up", waitUntil { h.lookup.requests == [songA.id, songB.id] }, "\(h.lookup.requests)")
    h.lookup.release(songA.id)  // the late answer for A
    h.spotify.advance(4.2)
    check("in flight: only B's line is shown", waitUntil { h.views.allSatisfy { $0.text == "B line 1" } }, h.describeViews())
}

scenario("playback ends during the debounce") { h in
    h.lookup.usesCache = false
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 0)
    spin(0.2)
    h.session.onEnded?()
    spin(LYRICS_FETCH_DEBOUNCE + 0.2)
    check("ended: the pending lookup never starts", h.lookup.requests.isEmpty, "\(h.lookup.requests)")
    check("ended: box empty", h.views.allSatisfy { $0.text == nil && $0.placeholder == nil && !$0.isVisible }, h.describeViews())
}

scenario("placeholder during the intro, not in mid-song gaps") { h in
    h.lookup.answers[songA.id] = syncedLyrics("A")  // intro until 4 s, instrumental gap at 20-28 s
    h.play(songA, at: 0)
    spin(ONE_TICK)
    check("intro: placeholder shows the title and artist", h.views.allSatisfy { $0.isVisible && $0.placeholder == "Song aaaa|Lantern Choir" && $0.text == nil }, h.describeViews())
    h.spotify.advance(2)
    spin(ONE_TICK)
    check("intro: still there mid-intro", h.views.allSatisfy { $0.placeholder != nil }, h.describeViews())
    h.spotify.advance(2)  // 4 s: the first line (lead included)
    spin(ONE_TICK)
    check("intro: first real line replaces it", h.views.allSatisfy { $0.text == "A line 1" && $0.placeholder == nil }, h.describeViews())
    h.spotify.advance(17)  // 21 s: inside the instrumental gap
    spin(ONE_TICK)
    check("gap: mid-song gap stays empty, no placeholder", h.views.allSatisfy { $0.text == nil && $0.placeholder == nil }, h.describeViews())
    h.spotify.advance(8)  // 29 s
    spin(ONE_TICK)
    check("gap: lines resume", h.views.allSatisfy { $0.text == "A verse 1" }, h.describeViews())
    h.seek(to: 1)
    spin(ONE_TICK)
    check("intro: a seek back into the intro shows it again", h.views.allSatisfy { $0.placeholder == "Song aaaa|Lantern Choir" }, h.describeViews())
    check("intro: trace has placeholder, without lyric text",
          h.traces.contains { $0.contains("placeholder") } && !h.traces.contains { $0.contains(" line ") || $0.contains("verse") })
}

scenario("placeholder: a leading blank line is still the intro") { h in
    var lines = [LyricLine(start: 0, end: 6, text: "", words: nil)]
    lines.append(LyricLine(start: 6, end: 10, text: "B line 1", words: nil))
    h.lookup.answers[songB.id] = TimedLyrics(lines: lines)
    h.play(songB, at: 1)
    spin(ONE_TICK)
    check("blank lead: placeholder", h.views.allSatisfy { $0.placeholder != nil }, h.describeViews())
    h.spotify.advance(5)
    spin(ONE_TICK)
    check("blank lead: then the line", h.views.allSatisfy { $0.text == "B line 1" && $0.placeholder == nil }, h.describeViews())
}

scenario("no placeholder for a song without lyrics") { h in
    h.lookup.usesCache = false  // network answers none after the debounce
    h.play(songB, at: 0)
    spin(ONE_TICK)
    check("none: placeholder while the lookup is pending", h.views.allSatisfy { $0.placeholder != nil }, h.describeViews())
    check("none: answered none after the debounce", waitUntil { h.lookup.requests == [songB.id] }, "\(h.lookup.requests)")
    spin(AFTER_FADE)
    check("none: box hidden, empty", h.views.allSatisfy { !$0.isVisible && $0.text == nil && $0.placeholder == nil }, h.describeViews())
    h.spotify.advance(10)
    spin(ONE_TICK)
    check("none: stays empty", h.views.allSatisfy { !$0.isVisible && $0.placeholder == nil }, h.describeViews())
}

scenario("placeholder respects the Lyrics tile and pause") { h in
    h.lookup.usesCache = false
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.settings.isLyricsEnabled = false
    h.play(songA, at: 0)
    spin(ONE_TICK)
    check("tile off: no placeholder visible while pending", h.views.allSatisfy { !$0.isVisible }, h.describeViews())
    h.settings.isLyricsEnabled = true
    spin(ONE_TICK)
    check("tile on: placeholder appears", h.views.allSatisfy { $0.isVisible && $0.placeholder != nil }, h.describeViews())
    h.pause()
    spin(ONE_TICK)
    check("paused: placeholder hidden", h.views.allSatisfy { !$0.isVisible }, h.describeViews())
    spin(AFTER_FADE)
    h.resume()
    spin(ONE_TICK)
    check("resumed: placeholder back", h.views.allSatisfy { $0.isVisible && $0.placeholder != nil }, h.describeViews())
}

scenario("placeholder redrawn on rebuilt windows") { h in
    h.lookup.usesCache = false
    h.lookup.answers[songA.id] = syncedLyrics("A")
    h.play(songA, at: 0)
    spin(ONE_TICK)
    h.rebuildWindows()
    spin(ONE_TICK)
    check("rebuild: new views show the placeholder", h.views.allSatisfy { $0.isVisible && $0.placeholder != nil }, h.describeViews())
}

suite.removePersistentDomain(forName: suiteName)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
