// One-shot "what is Spotify playing right now" query over AppleScript, plus the
// serial queue every Spotify AppleScript call shares. NSAppleScript isn't
// thread-safe, and Spotify answers slowly under load; one queue keeps scripts
// from overlapping and from stalling the main thread.
import AppKit

let SPOTIFY_BUNDLE_ID = "com.spotify.client"
let SPOTIFY_SCRIPT_QUEUE = DispatchQueue(label: "wallpaper-overlay.spotify-script", qos: .utility)
// state, id, name, artist, album, duration (ms), position (s)
let NOW_PLAYING_FIELD_COUNT = 7

// Locale-safe: "12,5", "12.5", "1.234,5" and "1,234.5" all parse; nil for junk
func parseLocaleNumber(_ text: String) -> Double? {
    var cleaned = text.trimmingCharacters(in: .whitespaces)
    let lastComma = cleaned.lastIndex(of: ",")
    let lastDot = cleaned.lastIndex(of: ".")
    switch (lastComma, lastDot) {
    case let (comma?, dot?):
        // Whichever comes last is the decimal mark; the other is grouping
        let decimal = comma > dot ? "," : "."
        let grouping = comma > dot ? "." : ","
        cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
        cleaned = cleaned.replacingOccurrences(of: decimal, with: ".")
    case (_?, nil):
        cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
    default:
        break
    }
    guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
    return value
}

// Pure so it can be tested. Lines: state, id, name, artist, album, duration, position.
// Shaped like Spotify's own notification userInfo so SpotifyWatcher.handle accepts it.
// A missing or unreadable number is left out rather than guessed as 0, since a
// made-up position would resync the lyrics to the start of the song.
func parseNowPlaying(_ output: String) -> [AnyHashable: Any]? {
    // Only the tail is trimmed: a leading blank line is an empty state field
    var body = Substring(output)
    while let last = body.last, last.isNewline { body = body.dropLast() }
    let fields = String(body)
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    // More fields than expected means a title with a line break: can't tell which is which
    guard fields.count >= 2, fields.count <= NOW_PLAYING_FIELD_COUNT else { return nil }
    let state = fields[0].trimmingCharacters(in: .whitespaces).capitalized
    guard !state.isEmpty else { return nil }
    func text(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
    var info: [AnyHashable: Any] = [
        "Player State": state,
        "Track ID": text(1),
        "Name": text(2),
        "Artist": text(3),
        "Album": text(4),
    ]
    if let duration = parseLocaleNumber(text(5)) { info["Duration"] = duration }
    if let position = parseLocaleNumber(text(6)) { info["Playback Position"] = position }
    return info
}

// Spotify's broadcast only arrives on changes, so ask once at launch what's
// already playing and replay it as if Spotify had just announced it.
// Only runs when Spotify is open, since the script would otherwise launch it.
// Completion runs on the main queue.
func fetchSpotifyNowPlaying(completion: @escaping ([AnyHashable: Any]?) -> Void) {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: SPOTIFY_BUNDLE_ID).isEmpty else {
        NSLog("wallpaper-overlay: Spotify isn't running at launch; waiting for its first broadcast")
        completion(nil)
        return
    }
    SPOTIFY_SCRIPT_QUEUE.async {
        let source = """
        tell application "Spotify"
            set t to current track
            return (player state as string) & linefeed & (id of t) & linefeed & (name of t) & linefeed & ¬
                (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position)
        end tell
        """
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        let info = output.flatMap(parseNowPlaying)
        if info == nil {
            let number = (error?[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "none"
            NSLog("wallpaper-overlay: couldn't read Spotify's current track (AppleScript error %@): %@",
                  number, error?.description ?? "no output")
        }
        DispatchQueue.main.async { completion(info) }
    }
}
