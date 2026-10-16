// Assert-style tests for SpotifyWatcher parsing and change callbacks.
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

w.start(); w.stop()
check("start/stop do not crash", true)

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
