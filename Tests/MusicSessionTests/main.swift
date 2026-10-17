// Assert-style tests for MusicSession, driven by fake Spotify notifications on an injected
// notification center, a canned AppleScript runner, a scheduler that records instead of
// sleeping, and an audio tap whose Core Audio build is stubbed.
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}

func spin(seconds: TimeInterval = 0.1) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// Waits until everything already queued on the tap's control queue has run
func settle(_ tap: SpotifyAudioTap) {
    let done = DispatchSemaphore(value: 0)
    tap.drain { done.signal() }
    done.wait()
}

// Spotify's distributed notification center, counting what the session attaches and detaches
final class CountingCenter: NotificationCenter, @unchecked Sendable {
    var added = 0
    var removed = 0
    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        added += 1
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}

// Shared between the main thread and the script queue
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

func song(_ id: String) -> SpotifyTrack {
    SpotifyTrack(id: SPOTIFY_TRACK_ID_PREFIX + id, name: "Paper Moon", artist: "Lantern Choir", album: "Night Songs", duration: 200)
}

// What Spotify's playback notification carries for a track
func payload(_ state: String, _ track: SpotifyTrack?, position: Double? = nil) -> [AnyHashable: Any] {
    var info: [AnyHashable: Any] = ["Player State": state]
    if let track {
        info["Track ID"] = track.id
        info["Name"] = track.name
        info["Artist"] = track.artist
        info["Album"] = track.album
        info["Duration"] = (track.duration ?? 0) * 1000
    }
    if let position { info["Playback Position"] = position }
    return info
}

// The launch-time script output for a track
func scriptOutput(_ state: String, _ track: SpotifyTrack, position: Double) -> String {
    [state, track.id, track.name, track.artist, track.album, "\(Int((track.duration ?? 0) * 1000))", "\(position)"]
        .joined(separator: "\n")
}

// One session plus everything it reported, wired the way OverlayController wires it.
// Spotify is faked at the lowest level: its notification center, the AppleScript
// runner, the app-running check, the scheduler and the tap build.
final class Harness {
    let center = CountingCenter()
    let workspaceCenter: NotificationCenter
    let tap: SpotifyAudioTap
    let appRunning = Flag(true)
    var session: MusicSession!
    var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
    var runningQueries: [String] = []
    var scriptRuns = 0
    var events: [String] = []
    var tracks: [SpotifyTrack] = []
    var positionAtTrack: SpotifyPositionStamp?
    // What the launch query prints; nil means no readable answer
    var launchOutput: String?
    // Stops the launch query inside the script runner until opened
    let launchGate = DispatchSemaphore(value: 0)
    var gatesLaunchQuery = false
    // Flipped to "quit" by the launch query itself, as if Spotify closed while it ran
    var quitsDuringQuery = false

    init(buildFails: Bool = false, workspaceCenter: NotificationCenter = NotificationCenter()) {
        self.workspaceCenter = workspaceCenter
        let tap = SpotifyAudioTap(buildOverride: {
            if buildFails { throw NSError(domain: "test", code: 1) }
        })
        self.tap = tap
        session = MusicSession(
            notificationCenter: center,
            runScript: { [unowned self] _ in
                self.scriptRuns += 1
                if self.gatesLaunchQuery { self.launchGate.wait() }
                if self.quitsDuringQuery { self.appRunning.value = false }
                return (self.launchOutput, nil)
            },
            makeTap: { tap },
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
            isAppRunning: { [unowned self] id in self.runningQueries.append(id); return self.appRunning.value },
            workspaceCenter: workspaceCenter)
        session.onTrack = { [unowned self] track in
            self.events.append("track")
            self.tracks.append(track)
            self.positionAtTrack = self.session.lastPosition
        }
        session.onPosition = { [unowned self] seconds in self.events.append("position \(seconds)") }
        session.onPlayState = { [unowned self] playing in self.events.append(playing ? "playing" : "paused") }
        session.onEnded = { [unowned self] in self.events.append("ended") }
    }

    // Posts Spotify's playback notification and lets the main queue deliver it
    func broadcast(_ state: String, _ track: SpotifyTrack?, position: Double? = nil) {
        center.post(name: SPOTIFY_NOTIFICATION, object: nil, userInfo: payload(state, track, position: position))
        spin(seconds: 0.02)
    }

    // Runs the scheduled suspends that weren't cancelled, as the main queue would
    func runScheduled() {
        scheduled.filter { !$0.work.isCancelled }.forEach { $0.work.perform() }
        scheduled = []
    }
}

// MARK: start
let h = Harness()
h.session.start()
check("start listens on the notification center once", h.center.added == 1)
check("start asks Spotify for the launch track", h.scriptRuns == 1)
check("idle at start: suspend scheduled after the grace period",
      h.scheduled.count == 1 && h.scheduled[0].delay == AUDIO_TAP_IDLE_GRACE && AUDIO_TAP_IDLE_GRACE == 15)
check("tap not suspended before the grace runs out", !h.tap.isSuspended)
h.runScheduled()
check("tap suspended once the grace runs out", h.tap.isSuspended)

// MARK: track, then lyrics/genre callbacks
h.broadcast("Playing", song("t1"), position: 3)
check("track, position, then play state", h.events == ["track", "position 3.0", "playing"])
check("onTrack carries the track", h.tracks == [song("t1")])
check("lastPosition is final inside onTrack (lyrics resync)", h.positionAtTrack?.seconds == 3)
check("session mirrors the watcher", h.session.isPlaying && h.session.track == song("t1"))
check("playing resumes the tap without scheduling", !h.tap.isSuspended && h.scheduled.isEmpty)
h.events = []
h.broadcast("Playing", song("t1"), position: 9)
check("same track: only the position", h.events == ["position 9.0"] && h.tracks.count == 1)
h.events = []
h.broadcast("Playing", song("t2"))
check("new track fires onTrack again, no state change", h.events == ["track"] && h.tracks.last == song("t2"))

// MARK: pause grace
h.events = []
h.broadcast("Paused", song("t2"))
check("pause with a track is not an end", h.events == ["paused"])
check("pause schedules the suspend after the grace",
      h.scheduled.count == 1 && h.scheduled[0].delay == AUDIO_TAP_IDLE_GRACE && !h.tap.isSuspended)
let pendingSuspend = h.scheduled[0].work
h.broadcast("Playing", song("t2"))
check("quick resume cancels the pending suspend", pendingSuspend.isCancelled)
h.runScheduled()
check("tap keeps running after a quick pause/play", !h.tap.isSuspended)
h.broadcast("Paused", song("t2"))
h.broadcast("Playing", song("t2"))
h.broadcast("Paused", song("t2"))
check("only the latest suspend stays live", h.scheduled.filter { !$0.work.isCancelled }.count == 1)
h.runScheduled()
check("a long pause suspends the tap", h.tap.isSuspended)

// MARK: stopped with no track
h.broadcast("Playing", song("t3"))
h.events = []
h.scheduled = []
h.broadcast("Stopped", nil)
check("stop without a track reports paused, then ended", h.events == ["paused", "ended"])
check("stop keeps the normal grace", h.scheduled.count == 1 && h.scheduled[0].delay == AUDIO_TAP_IDLE_GRACE)

// MARK: quit, then reset and ended
h.broadcast("Playing", song("t4"), position: 12)
h.events = []
h.scheduled = []
h.session.appTerminated(bundleID: "com.example.other-app")
check("another app quitting is ignored", h.session.isPlaying && h.events.isEmpty && h.scheduled.isEmpty)
h.session.appTerminated(bundleID: nil)
check("an app without a bundle ID is ignored", h.session.isPlaying && h.events.isEmpty)
h.session.appTerminated(bundleID: SPOTIFY_BUNDLE_ID)
check("quit forgets the track and position", h.session.track == nil && h.session.lastPosition == nil)
check("quit reports paused, then ended", h.events.first == "paused" && h.events.last == "ended" && !h.session.isPlaying)
check("quit suspends the tap immediately (last scheduled delay is 0)",
      h.scheduled.last?.delay == 0 && h.scheduled.filter { !$0.work.isCancelled }.count == 1)
h.runScheduled()
check("tap suspended after quit", h.tap.isSuspended)
h.events = []
h.session.appTerminated(bundleID: SPOTIFY_BUNDLE_ID)
check("quitting again while stopped still ends (idempotent for lyrics)", h.events == ["ended"])

// MARK: termination observer wiring
let workspace = NotificationCenter()
let observed = Harness(workspaceCenter: workspace)
observed.session.start()
observed.broadcast("Playing", song("o1"))
workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
               userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
spin()
check("termination of a different app (this test binary) leaves the session alone",
      observed.session.isPlaying && observed.session.track == song("o1"))

// MARK: launch bootstrap
let launchSnapshotOutput = scriptOutput("playing", song("launch"), position: 42)

func bootstrapped(running: Bool, trackFirst: Bool, output: String?, quitsDuringQuery: Bool = false) -> Harness {
    let b = Harness()
    b.appRunning.value = running
    b.launchOutput = output
    b.quitsDuringQuery = quitsDuringQuery
    b.gatesLaunchQuery = trackFirst
    b.session.start()
    if trackFirst {
        // A broadcast lands while the launch query is still running
        b.broadcast("Playing", song("live"))
    }
    b.events = []
    b.tracks = []
    b.launchGate.signal()
    spin()
    return b
}

let applied = bootstrapped(running: true, trackFirst: false, output: launchSnapshotOutput)
check("bootstrap applied when Spotify runs and no track yet",
      applied.tracks == [song("launch")] && applied.events == ["track", "position 42.0", "playing"])
check("bootstrap checks Spotify's bundle ID", !applied.runningQueries.isEmpty
      && applied.runningQueries.allSatisfy { $0 == SPOTIFY_BUNDLE_ID })
check("bootstrap playing resumes the tap", !applied.tap.isSuspended)

let closed = bootstrapped(running: false, trackFirst: false, output: launchSnapshotOutput)
check("bootstrap skipped when Spotify isn't running (the script would launch it)",
      closed.scriptRuns == 0 && closed.tracks.isEmpty && closed.session.track == nil)

let quit = bootstrapped(running: true, trackFirst: false, output: launchSnapshotOutput, quitsDuringQuery: true)
check("bootstrap dropped when Spotify quit while the query ran",
      quit.scriptRuns == 1 && quit.tracks.isEmpty && quit.session.track == nil)

let raced = bootstrapped(running: true, trackFirst: true, output: launchSnapshotOutput)
check("bootstrap dropped when a broadcast already set the track",
      raced.tracks.isEmpty && raced.session.track == song("live"))

let unreadable = bootstrapped(running: true, trackFirst: false, output: nil)
check("no answer changes nothing", unreadable.tracks.isEmpty && unreadable.events.isEmpty)

// MARK: audio levels
let healthy = Harness()
healthy.session.start()
settle(healthy.tap)
check("levels available once the tap is built", healthy.session.audioLevels() != nil)
let broken = Harness(buildFails: true)
broken.session.start()
settle(broken.tap)
check("no levels when the tap couldn't be built (glow falls back to play state)",
      broken.session.audioLevels() == nil)

// MARK: playback clock
let clock = healthy.session.makePlaybackClock()
check("playback clock starts unsynced", clock.position() == nil && clock.isAvailable)

// MARK: lifetime
let counted = Harness()
var shortLived: MusicSession? = MusicSession(
    notificationCenter: counted.center, runScript: { _ in (nil, nil) }, makeTap: { counted.tap },
    schedule: { _, _ in }, isAppRunning: { _ in true }, workspaceCenter: NotificationCenter())
shortLived?.start()
let removedBefore = counted.center.removed
shortLived = nil
check("releasing the session stops its watcher", shortLived == nil && counted.center.removed == removedBefore + 1)

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
