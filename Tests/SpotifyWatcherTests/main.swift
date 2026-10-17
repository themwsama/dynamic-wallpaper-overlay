// Assert-style tests for SpotifyWatcher parsing, change callbacks and its injected seams.
import Foundation
import QuartzCore

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}

func info(_ state: String?, _ id: String?, name: String = "N", artist: String = "A", album: String = "B") -> [AnyHashable: Any] {
    var d: [AnyHashable: Any] = ["Name": name, "Artist": artist, "Album": album]
    if let state { d["Player State"] = state }
    if let id { d["Track ID"] = id }
    return d
}

let playing = SpotifyWatcher.parse(info("Playing", "spotify:track:abc"))
check("playing track", playing.isPlaying && playing.track == SpotifyTrack(id: "spotify:track:abc", name: "N", artist: "A", album: "B", duration: nil))

let paused = SpotifyWatcher.parse(info("Paused", "spotify:track:abc"))
check("paused keeps track", !paused.isPlaying && paused.track?.id == "spotify:track:abc")

let stopped = SpotifyWatcher.parse(["Player State": "Stopped"])
check("stopped no id", !stopped.isPlaying && stopped.track == nil)

check("empty id", SpotifyWatcher.parse(info("Playing", "")).track == nil)
check("episode id", SpotifyWatcher.parse(info("Playing", "spotify:episode:xyz")).track == nil)
check("local file id", SpotifyWatcher.parse(info("Playing", "spotify:local:a:b:c:1")).track == nil)
let missing = SpotifyWatcher.parse([:])
check("missing keys", missing.track == nil && !missing.isPlaying)
let noMeta = SpotifyWatcher.parse(["Player State": "Playing", "Track ID": "spotify:track:q"])
check("missing metadata defaults to empty", noMeta.track == SpotifyTrack(id: "spotify:track:q", name: "", artist: "", album: "", duration: nil))

let w = SpotifyWatcher()
var trackFires = 0
var states: [Bool] = []
w.onTrackChange = { _ in trackFires += 1 }
w.onStateChange = { states.append($0) }
w.handle(info("Playing", "spotify:track:abc"))
w.handle(info("Playing", "spotify:track:abc"))
w.handle(info("Paused", "spotify:track:abc"))
check("onTrackChange once for same id", trackFires == 1)
check("onStateChange only on change", states == [true, false])
w.handle(info("Playing", "spotify:track:def"))
check("onTrackChange fires for new id", trackFires == 2 && w.track?.id == "spotify:track:def")
w.handle(["Player State": "Stopped"])
check("stopped clears track", w.track == nil && !w.isPlaying)

let dur = SpotifyWatcher.parse(["Player State": "Playing", "Track ID": "spotify:track:d", "Duration": 215000, "Playback Position": 12.5])
check("duration ms Int to seconds", dur.track?.duration == 215)
check("position parsed", dur.position == 12.5)
let durD = SpotifyWatcher.parse(["Track ID": "spotify:track:d", "Duration": 215500.0])
check("duration Double", durD.track?.duration == 215.5 && durD.position == nil)
check("no duration is nil", noMeta.track?.duration == nil)
check("negative duration ignored", SpotifyWatcher.parse(["Track ID": "spotify:track:d", "Duration": -5]).track?.duration == nil)
check("duration affects equality", dur.track != durD.track)

let pw = SpotifyWatcher()
var positions: [Double] = []
var pTrackFires = 0
pw.onPositionUpdate = { positions.append($0) }
pw.onTrackChange = { _ in pTrackFires += 1 }
check("lastPosition nil initially", pw.lastPosition == nil)
let before = CACurrentMediaTime()
pw.handle(["Player State": "Playing", "Track ID": "spotify:track:p", "Playback Position": 3.0])
check("lastPosition stamped", pw.lastPosition?.seconds == 3.0 && (pw.lastPosition!.at >= before) && pw.lastPosition!.at <= CACurrentMediaTime())
pw.handle(["Player State": "Playing", "Track ID": "spotify:track:p", "Playback Position": 9.0])
check("onPositionUpdate each notification, track change once", positions == [3.0, 9.0] && pTrackFires == 1)
pw.handle(["Player State": "Paused", "Track ID": "spotify:track:p"])
check("no position key keeps last", pw.lastPosition?.seconds == 9.0 && positions.count == 2)

// Callback order: track, then position, then state
let ow = SpotifyWatcher()
var order: [String] = []
var seenInTrackCallback: (Bool, Double?)?
ow.onTrackChange = { _ in order.append("track"); seenInTrackCallback = (ow.isPlaying, ow.lastPosition?.seconds) }
ow.onPositionUpdate = { _ in order.append("position") }
ow.onStateChange = { _ in order.append("state") }
ow.handle(["Player State": "Playing", "Track ID": "spotify:track:o1", "Playback Position": 4.0])
check("callback order track, position, state", order == ["track", "position", "state"])
check("fields are final before the first callback", seenInTrackCallback?.0 == true && seenInTrackCallback?.1 == 4.0)
order = []
ow.handle(["Player State": "Paused", "Track ID": "spotify:track:o1", "Playback Position": 5.0])
check("position then state without a track change", order == ["position", "state"])
order = []
ow.handle(["Player State": "Paused", "Track ID": "spotify:track:o1"])
check("no callbacks when nothing changed", order.isEmpty)

// reset(): clears everything and reports the stop once
let rw = SpotifyWatcher()
var rStates: [Bool] = []
rw.onStateChange = { rStates.append($0) }
rw.handle(["Player State": "Playing", "Track ID": "spotify:track:r1", "Playback Position": 2.0])
rStates = []
rw.reset()
check("reset clears track, position and play state", rw.track == nil && rw.lastPosition == nil && !rw.isPlaying)
check("reset fires onStateChange(false) when it was playing", rStates == [false])
rw.reset()
check("reset when already stopped fires nothing", rStates == [false])
let pausedW = SpotifyWatcher()
var pausedStates: [Bool] = []
pausedW.onStateChange = { pausedStates.append($0) }
pausedW.handle(["Player State": "Paused", "Track ID": "spotify:track:r2"])
pausedW.reset()
check("reset while paused clears the track without a state callback", pausedW.track == nil && pausedStates.isEmpty)
var replayed = 0
rw.onTrackChange = { _ in replayed += 1 }
rw.handle(["Player State": "Playing", "Track ID": "spotify:track:r1"])
check("same track after reset counts as a new track", replayed == 1)

w.start(); w.stop()
check("start/stop do not crash", true)

// Identity
check("position source runs on the shared script queue", SpotifyWatcher().makePositionSource().queue === SPOTIFY_SCRIPT_QUEUE)
check("scripts target Spotify", SpotifyWatcher().positionScript.contains("\"Spotify\"")
      && SpotifyWatcher().nowPlayingScript.contains("\"Spotify\""))
let aw = SpotifyWatcher()
var applied: [String] = []
aw.onTrackChange = { _ in applied.append("track") }
aw.onPositionUpdate = { _ in applied.append("position") }
aw.onStateChange = { _ in applied.append("state") }
aw.apply(SpotifySnapshot(track: SpotifyTrack(id: "spotify:track:a1", name: "N", artist: "A", album: "B", duration: 10),
                            isPlaying: true, position: 1.5))
check("apply behaves like a notification", applied == ["track", "position", "state"]
      && aw.track?.id == "spotify:track:a1" && aw.lastPosition?.seconds == 1.5 && aw.isPlaying)

// Injected notification center: start() listens for Spotify's broadcast, stop() detaches
let center = NotificationCenter()
let cw = SpotifyWatcher(center: center)
var centerTracks: [String] = []
cw.onTrackChange = { centerTracks.append($0.id) }
cw.start()
cw.start()
center.post(name: SPOTIFY_NOTIFICATION, object: nil, userInfo: info("Playing", "spotify:track:n1"))
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check("notification on the injected center is handled once", centerTracks == ["spotify:track:n1"])
center.post(name: SPOTIFY_NOTIFICATION, object: nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check("notification without userInfo is ignored", centerTracks.count == 1 && cw.isPlaying)
cw.stop()
center.post(name: SPOTIFY_NOTIFICATION, object: nil, userInfo: info("Playing", "spotify:track:n2"))
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check("stop detaches from the center", centerTracks.count == 1)

// fetchNowPlaying: injected app-running check and script runner
func fetch(running: Bool, output: String?, error: NSDictionary? = nil) -> (snapshot: SpotifySnapshot?, ran: [String], asked: [String]) {
    var ran: [String] = []
    var asked: [String] = []
    let f = SpotifyWatcher(runScript: { ran.append($0); return (output, error) },
                           isAppRunning: { asked.append($0); return running })
    var done = false
    var result: SpotifySnapshot?
    f.fetchNowPlaying { result = $0; done = true }
    let end = Date().addingTimeInterval(5)
    while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    return (result, ran, asked)
}
let live = fetch(running: true, output: "playing\nspotify:track:f1\nN\nA\nB\n215000\n12.5")
check("fetch parses the script output", live.snapshot?.isPlaying == true && live.snapshot?.track?.id == "spotify:track:f1"
      && live.snapshot?.position == 12.5 && live.snapshot?.track?.duration == 215)
check("fetch asks about Spotify's bundle ID and runs the now-playing script",
      live.asked == [SPOTIFY_BUNDLE_ID] && live.ran == [SpotifyWatcher().nowPlayingScript])
let closed = fetch(running: false, output: "playing\nspotify:track:f1\nN\nA\nB\n1\n2")
check("fetch while Spotify is closed runs no script", closed.snapshot == nil && closed.ran.isEmpty)
check("fetch with unreadable output yields nil", fetch(running: true, output: nil).snapshot == nil)
check("fetch with a script error yields nil",
      fetch(running: true, output: nil, error: [NSAppleScript.errorNumber: -1743] as NSDictionary).snapshot == nil)

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
