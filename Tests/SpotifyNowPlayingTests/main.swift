// Assert-style tests for the pure now-playing parser (invented track data).
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}

let full = "playing\nspotify:track:abc\nPaper Moon\nLantern Choir\nNight Songs\n215000\n12.5"
let info = parseNowPlaying(full)
check("full output parses", info != nil)
check("state is capitalized", info?["Player State"] as? String == "Playing")
check("text fields", info?["Track ID"] as? String == "spotify:track:abc" && info?["Name"] as? String == "Paper Moon"
    && info?["Artist"] as? String == "Lantern Choir" && info?["Album"] as? String == "Night Songs")
check("numbers are NSNumber", (info?["Duration"] as? NSNumber)?.doubleValue == 215000 && (info?["Playback Position"] as? NSNumber)?.doubleValue == 12.5)

let comma = parseNowPlaying("paused\nspotify:track:abc\nN\nA\nB\n215000,0\n12,5")
check("decimal comma position", (comma?["Playback Position"] as? NSNumber)?.doubleValue == 12.5)
check("decimal comma duration", (comma?["Duration"] as? NSNumber)?.doubleValue == 215000)
check("paused state", comma?["Player State"] as? String == "Paused")

check("grouped comma-decimal", parseLocaleNumber("1.234,5") == 1234.5)
check("grouped dot-decimal", parseLocaleNumber("1,234.5") == 1234.5)
check("plain integer", parseLocaleNumber("215000") == 215000)
check("scientific", parseLocaleNumber("2.15E+5") == 215000)
check("junk is nil", parseLocaleNumber("missing value") == nil && parseLocaleNumber("") == nil)
check("negative is nil", parseLocaleNumber("-3") == nil)
check("infinity is nil", parseLocaleNumber("inf") == nil)

let missingNumbers = parseNowPlaying("playing\nspotify:track:abc\nN\nA\nB\nmissing value\n")
check("unreadable numbers omitted, not zero", missingNumbers != nil && missingNumbers?["Duration"] == nil && missingNumbers?["Playback Position"] == nil)

let truncated = parseNowPlaying("playing\nspotify:track:abc\nN")
check("short output keeps what it has", truncated?["Name"] as? String == "N" && truncated?["Artist"] as? String == "" && truncated?["Playback Position"] == nil)

let emptyArtist = parseNowPlaying("playing\nspotify:track:abc\nN\n\nB\n1000\n2")
check("empty middle field keeps positions", emptyArtist?["Artist"] as? String == "" && emptyArtist?["Album"] as? String == "B"
    && (emptyArtist?["Playback Position"] as? NSNumber)?.doubleValue == 2)

check("trailing newline tolerated", parseNowPlaying(full + "\n")?["Name"] as? String == "Paper Moon")
check("CRLF tolerated", parseNowPlaying(full.replacingOccurrences(of: "\n", with: "\r\n"))?["Playback Position"] != nil)
check("empty output nil", parseNowPlaying("") == nil)
check("blank state nil", parseNowPlaying("\nspotify:track:abc\nN\nA\nB\n1\n2") == nil)
check("single field nil", parseNowPlaying("playing") == nil)
check("extra line breaks nil", parseNowPlaying(full + "\nextra") == nil)

if let info {
    let parsed = SpotifyWatcher.parse(info)
    check("watcher accepts the dictionary", parsed.isPlaying && parsed.track?.duration == 215 && parsed.position == 12.5)
}
check("queue label", SPOTIFY_SCRIPT_QUEUE.label == "wallpaper-overlay.spotify-script")
check("bundle id", SPOTIFY_BUNDLE_ID == "com.spotify.client")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
