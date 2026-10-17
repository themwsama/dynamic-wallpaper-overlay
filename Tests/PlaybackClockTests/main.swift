// Assert-style tests for PlaybackClock with a fake source and fake time.
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
func near(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

let queueKey = DispatchSpecificKey<Bool>()
let scriptQueue = DispatchQueue(label: "test.script-queue")
scriptQueue.setSpecific(key: queueKey, value: true)

final class FakeSource: SpotifyPositionSource {
    let queue = scriptQueue
    private let lock = NSLock()
    private var value: TimeInterval?
    private var count = 0
    private var offQueue = 0
    private var error: Int?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var callsOffSharedQueue: Int { lock.lock(); defer { lock.unlock() }; return offQueue }
    var lastErrorNumber: Int? { lock.lock(); defer { lock.unlock() }; return value == nil ? error : nil }
    func set(_ v: TimeInterval?, error: Int? = nil) { lock.lock(); value = v; self.error = error; lock.unlock() }
    func currentPosition() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if DispatchQueue.getSpecific(key: queueKey) != true { offQueue += 1 }
        return value
    }
}

func spin(_ cond: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

var time: CFTimeInterval = 1000
var running = true
var logs: [String] = []
let source = FakeSource()
let clock = PlaybackClock(bundleID: "com.example.player", source: source,
                          now: { time }, isAppRunning: { running }, log: { logs.append($0) })

func poll(_ v: TimeInterval?, error: Int? = nil) {
    source.set(v, error: error)
    var done = false
    clock.pollOnce { done = true }
    spin { done }
}

check("no position before sync", clock.position() == nil)
clock.resync(position: 10)
check("frozen when not playing", near(clock.position(), 10))
time += 5
check("still frozen after time passes", near(clock.position(), 10))
clock.setPlaying(true)
time += 3
check("interpolates while playing", near(clock.position(), 13))
clock.setPlaying(false)
time += 10
check("pause freezes at interpolated", near(clock.position(), 13))
clock.setPlaying(true)
time += 1
check("resume continues", near(clock.position(), 14))

poll(14.1)
check("small correction does not jump", near(clock.position(), 14))
time += 1
check("continues after small correction", near(clock.position(), 15))
poll(60)
check("seek jumps", near(clock.position(), 60))

clock.resync(position: 30)
check("resync sets position", near(clock.position(), 30))
time += 2
check("resync anchors time", near(clock.position(), 32))

clock.reset()
check("reset goes to 0", near(clock.position(), 0))
time += 4
check("reset waits (frozen) for sync", near(clock.position(), 0))
poll(1.0)
check("first poll after reset anchors even if small", near(clock.position(), 1.0))
time += 1
check("plays on after sync", near(clock.position(), 2.0))

let calls = source.calls
running = false
poll(5)
check("no query when the app is not running", source.calls == calls && near(clock.position(), 2.0))
running = true
check("queries run on the source's script queue", source.calls > 0 && source.callsOffSharedQueue == 0)

// Without an injected check, the clock asks NSWorkspace about its own bundle ID
let defaultSource = FakeSource()
defaultSource.set(5)
let defaultClock = PlaybackClock(bundleID: "com.example.not-installed-\(UUID().uuidString)",
                                 source: defaultSource, now: { time }, log: { _ in })
var defaultDone = false
defaultClock.setPlaying(true)
defaultClock.pollOnce { defaultDone = true }
spin { defaultDone }
check("default running check uses the bundle ID (absent app is never queried)", defaultSource.calls == 0)
defaultClock.setPlaying(false)

// MARK: backoff and recovery
check("available initially", clock.isAvailable)
check("normal poll interval while available", clock.pollInterval == PLAYBACK_POLL_INTERVAL)
poll(nil); poll(nil)
check("still available after 2 nils", clock.isAvailable)
poll(7)
poll(nil); poll(nil)
check("success resets nil count", clock.isAvailable)
check("no log before the state changes", logs.isEmpty)
poll(nil, error: -1743)
check("unavailable after 3 nils in a row", !clock.isAvailable)
check("backs off to the retry interval", clock.pollInterval == PLAYBACK_RETRY_INTERVAL && PLAYBACK_RETRY_INTERVAL == 60)
check("logs once with the AppleScript error number", logs.count == 1 && logs[0].contains("-1743"))
check("log names the app", logs[0].contains("Spotify position unavailable"))
check("-1743 is logged as permission denied", logs[0].contains("permission denied"))
poll(nil, error: -1743); poll(nil, error: -1743)
check("further failures stay quiet", logs.count == 1 && !clock.isAvailable)
let probes = source.calls
poll(nil)
check("still probes while unavailable", source.calls == probes + 1)
clock.resync(position: 50)
check("resync still works when unavailable", near(clock.position(), 50))
poll(52)
check("a successful probe restores availability and normal polling", clock.isAvailable && clock.pollInterval == PLAYBACK_POLL_INTERVAL)
check("recovery is logged once", logs.count == 2)
check("recovery applied the position", near(clock.position(), 52))
poll(nil, error: -1743); poll(nil, error: -1743)
check("failure count restarts after recovery", clock.isAvailable)
poll(nil, error: -1743)
check("goes unavailable again after 3 more", !clock.isAvailable && logs.count == 3)
poll(60)
check("recovers again", clock.isAvailable && logs.count == 4)
poll(61)

// MARK: which errors slow the poll
let logsBefore = logs.count
for _ in 0..<(PLAYBACK_MAX_FAILURES + 4) { poll(nil, error: -1728) }
check("-1728 (no current track) keeps fast polling", clock.isAvailable && clock.pollInterval == PLAYBACK_POLL_INTERVAL)
check("-1728 is logged once, not as permission denied",
      logs.count == logsBefore + 1 && logs.last?.contains("-1728") == true && logs.last?.contains("permission denied") == false)
poll(62)
check("success after transient failures logs nothing more", logs.count == logsBefore + 1 && clock.isAvailable)
for _ in 0..<(PLAYBACK_MAX_FAILURES + 2) { poll(nil) }
check("a timeout with no error number keeps fast polling", clock.isAvailable && clock.pollInterval == PLAYBACK_POLL_INTERVAL)
check("missing error number is logged as none", logs.last?.contains("error none") == true)
poll(63)
for _ in 0..<PLAYBACK_MAX_FAILURES { poll(nil, error: -600) }
check("-600 (app not running) slows to the retry interval",
      !clock.isAvailable && clock.pollInterval == PLAYBACK_RETRY_INTERVAL)
check("-600 is logged with its number and not as permission denied",
      logs.last?.contains("-600") == true && logs.last?.contains("permission denied") == false)
check("-600 reason names the app", logs.last?.contains("Spotify not running") == true)
poll(64)
check("recovers from -600", clock.isAvailable)
poll(nil, error: -1728); poll(nil, error: -1728); poll(nil, error: -1743)
check("failure streak counts across error kinds", !clock.isAvailable)
poll(65)

// MARK: stale polls
func pollThen(_ v: TimeInterval?, between: () -> Void) {
    source.set(v)
    var done = false
    clock.pollOnce { done = true }
    between()  // runs before the poll's result gets applied on main
    spin { done }
}
clock.resync(position: 20)
pollThen(99) { clock.resync(position: 25) }
check("poll started before a resync is dropped", near(clock.position(), 25))

clock.resync(position: 40)
pollThen(88) { clock.reset() }
check("poll started before a reset is dropped", near(clock.position(), 0))
time += 3
check("dropped poll leaves the clock waiting for sync", near(clock.position(), 0))
poll(5)
check("next poll after the drop still anchors", near(clock.position(), 5))

clock.resync(position: 30)
let failuresBefore = logs.count
for _ in 0..<5 { pollThen(nil) { clock.resync(position: 30) } }
check("stale failures do not count toward unavailable", clock.isAvailable && logs.count == failuresBefore)

clock.resync(position: 30)
pollThen(90) { }
check("a poll with no intervening change is applied", near(clock.position(), 90))

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
