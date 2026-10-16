// Assert-style tests for PlaybackClock with a fake source and fake time.
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
func near(_ a: TimeInterval?, _ b: TimeInterval) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

final class FakeSource: SpotifyPositionSource {
    private let lock = NSLock()
    private var value: TimeInterval?
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ v: TimeInterval?) { lock.lock(); value = v; lock.unlock() }
    func currentPosition() -> TimeInterval? { lock.lock(); defer { lock.unlock() }; count += 1; return value }
}

var time: CFTimeInterval = 1000
var running = true
let source = FakeSource()
let clock = PlaybackClock(source: source, now: { time }, isSpotifyRunning: { running })

func poll(_ v: TimeInterval?) {
    source.set(v)
    clock.pollOnce()
    let deadline = Date().addingTimeInterval(2)
    let target = source.calls
    // wait for the queue hop and the main hop
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); if source.calls >= target && Date() > deadline.addingTimeInterval(-1.95) { break } }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
check("no query when Spotify not running", source.calls == calls && near(clock.position(), 2.0))
running = true

check("available initially", clock.isAvailable)
poll(nil); poll(nil)
check("still available after 2 nils", clock.isAvailable)
poll(7)
poll(nil); poll(nil)
check("success resets nil count", clock.isAvailable)
poll(nil)
check("unavailable after 3 nils in a row", !clock.isAvailable)
clock.resync(position: 50)
check("resync still works when unavailable", near(clock.position(), 50))

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
