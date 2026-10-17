// Follows Spotify. Track and play-state changes come from the desktop app's
// distributed playback notification (no polling, no permission). The launch-time
// "what's playing" query and the position poll go over AppleScript (Automation
// permission), all on one serial queue: NSAppleScript isn't thread-safe, and
// Spotify answers slowly under load, so one queue keeps scripts from overlapping
// and from stalling the main thread.
import AppKit
import QuartzCore

nonisolated let SPOTIFY_BUNDLE_ID = "com.spotify.client"
nonisolated let SPOTIFY_DISPLAY_NAME = "Spotify"
nonisolated let SPOTIFY_SCRIPT_QUEUE = DispatchQueue(label: "wallpaper-overlay.spotify-script", qos: .utility)
nonisolated let SPOTIFY_NOTIFICATION = Notification.Name("com.spotify.client.PlaybackStateChanged")
nonisolated let SPOTIFY_TRACK_ID_PREFIX = "spotify:track:"  // excludes episodes and local files
nonisolated let SPOTIFY_PLAYING_STATE = "Playing"
nonisolated let SPOTIFY_MS_PER_SECOND: Double = 1000  // "Duration" is milliseconds, "Playback Position" is seconds
nonisolated let SPOTIFY_KNOWN_STATES: Set<String> = [SPOTIFY_PLAYING_STATE, "Paused", "Stopped"]
// state, id, name, artist, album, duration (ms), position (s)
nonisolated let NOW_PLAYING_FIELD_COUNT = 7

// Nonisolated and Sendable: parsed off the main actor (notification and script queues)
nonisolated struct SpotifyTrack: Equatable, Sendable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval?
}

// A reported position and the CACurrentMediaTime it was received at
typealias SpotifyPositionStamp = (seconds: TimeInterval, at: CFTimeInterval)

// One report from Spotify: what's on, whether it plays, and where it is
nonisolated struct SpotifySnapshot: Sendable {
    let track: SpotifyTrack?
    let isPlaying: Bool
    let position: TimeInterval?
}

// Runs an AppleScript source and returns its text output, or the error dictionary
// when it failed. Called on SPOTIFY_SCRIPT_QUEUE, so it must be Sendable and nonisolated.
typealias SpotifyScriptRunner = @Sendable (_ source: String) -> (output: String?, error: NSDictionary?)

nonisolated func runAppleScript(_ source: String) -> (output: String?, error: NSDictionary?) {
    var error: NSDictionary?
    let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    return (output, error)
}

// Main-thread only. Callbacks fire as track change, then position, then state,
// and every field is final before the first one.
final class SpotifyWatcher {
    let scriptQueue = SPOTIFY_SCRIPT_QUEUE
    let nowPlayingScript = """
        tell application "Spotify"
            set t to current track
            return (player state as string) & linefeed & (id of t) & linefeed & (name of t) & linefeed & ¬
                (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position)
        end tell
        """
    let positionScript = "tell application \"Spotify\" to player position"

    private let center: NotificationCenter
    private let runScript: SpotifyScriptRunner
    private let isAppRunning: (String) -> Bool
    private(set) var track: SpotifyTrack?
    private(set) var isPlaying = false
    private(set) var lastPosition: SpotifyPositionStamp?
    var onTrackChange: ((SpotifyTrack) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onPositionUpdate: ((TimeInterval) -> Void)?
    private var observer: NSObjectProtocol?

    // The defaults are the real thing; tests pass a private center, a canned script runner
    // and an app-running check
    init(
        center: NotificationCenter = DistributedNotificationCenter.default(),
        runScript: @escaping SpotifyScriptRunner = runAppleScript,
        isAppRunning: @escaping (String) -> Bool = isApplicationRunning
    ) {
        self.center = center
        self.runScript = runScript
        self.isAppRunning = isAppRunning
    }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: SPOTIFY_NOTIFICATION, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo else {
                NSLog("wallpaper-overlay: Spotify notification without userInfo")
                return
            }
            // Parsed here so only the Sendable snapshot crosses into the main actor;
            // delivered on `.main`, so this really is on the main actor
            let snapshot = SpotifyWatcher.parse(info)
            MainActor.assumeIsolated { self?.apply(snapshot) }
        }
    }

    func stop() {
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }

    // Pure so it can be tested without notifications. Nonisolated: also runs in the
    // notification block before the hop to the main actor
    nonisolated static func parse(_ userInfo: [AnyHashable: Any]) -> SpotifySnapshot {
        let state = userInfo["Player State"] as? String
        if state == nil || !SPOTIFY_KNOWN_STATES.contains(state!) {
            NSLog("wallpaper-overlay: unexpected Spotify Player State: \(String(describing: userInfo["Player State"]))")
        }
        let isPlaying = state == SPOTIFY_PLAYING_STATE
        let position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue.nonNegativeFinite

        let id = (userInfo["Track ID"] as? String) ?? ""
        guard !id.isEmpty else { return SpotifySnapshot(track: nil, isPlaying: isPlaying, position: position) }
        guard id.hasPrefix(SPOTIFY_TRACK_ID_PREFIX) else {
            NSLog("wallpaper-overlay: ignoring non-track Spotify ID: \(id)")
            return SpotifySnapshot(track: nil, isPlaying: isPlaying, position: position)
        }
        let track = SpotifyTrack(
            id: id,
            name: userInfo["Name"] as? String ?? "",
            artist: userInfo["Artist"] as? String ?? "",
            album: userInfo["Album"] as? String ?? "",
            duration: (userInfo["Duration"] as? NSNumber)?.doubleValue.nonNegativeFinite.map { $0 / SPOTIFY_MS_PER_SECOND }
        )
        return SpotifySnapshot(track: track, isPlaying: isPlaying, position: position)
    }

    func handle(_ userInfo: [AnyHashable: Any]) {
        apply(Self.parse(userInfo))
    }

    // Callbacks fire as track change, then position, then state, so a listener
    // that starts work on "playing" already knows the new track and where in it we are.
    // All fields are updated first, so every callback sees the final state.
    func apply(_ snapshot: SpotifySnapshot) {
        let previousID = track?.id
        track = snapshot.track
        if let seconds = snapshot.position { lastPosition = (seconds, CACurrentMediaTime()) }
        let stateChanged = isPlaying != snapshot.isPlaying
        isPlaying = snapshot.isPlaying

        if let newTrack = snapshot.track, newTrack.id != previousID { onTrackChange?(newTrack) }
        if let seconds = snapshot.position { onPositionUpdate?(seconds) }
        if stateChanged { onStateChange?(snapshot.isPlaying) }
    }

    // Spotify quit: forget the song and report the stop, so nothing keeps
    // interpolating a position for a player that's gone
    func reset() {
        track = nil
        lastPosition = nil
        guard isPlaying else { return }
        isPlaying = false
        onStateChange?(false)
    }

    // Spotify's broadcast only arrives on changes, so ask once at launch what's
    // already playing. Only runs when Spotify is open, since the script would
    // otherwise launch it. Completion runs on the main queue; nil when unknown.
    func fetchNowPlaying(completion: @escaping (SpotifySnapshot?) -> Void) {
        guard isAppRunning(SPOTIFY_BUNDLE_ID) else {
            NSLog("wallpaper-overlay: %@ isn't running at launch; waiting for its first broadcast", SPOTIFY_DISPLAY_NAME)
            completion(nil)
            return
        }
        let script = nowPlayingScript
        let runScript = runScript
        // Built here on the main actor and only ever called there; the script
        // queue below is nonisolated and hands over just the Sendable snapshot
        let deliver: @MainActor @Sendable (SpotifySnapshot?) -> Void = { completion($0) }
        scriptQueue.async {
            let result = runScript(script)
            let info = result.output.flatMap(parseNowPlaying)
            if info == nil {
                let number = (result.error?[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "none"
                NSLog("wallpaper-overlay: couldn't read %@'s current track (AppleScript error %@): %@",
                      SPOTIFY_DISPLAY_NAME, number, result.error?.description ?? "no output")
            }
            let snapshot = info.map(SpotifyWatcher.parse)
            DispatchQueue.main.async { deliver(snapshot) }
        }
    }

    func makePositionSource() -> SpotifyPositionSource {
        AppleScriptPositionSource(script: positionScript, queue: scriptQueue)
    }
}

// Locale-safe: "12,5", "12.5", "1.234,5" and "1,234.5" all parse; nil for junk.
// Nonisolated: runs on the script queue.
nonisolated func parseLocaleNumber(_ text: String) -> Double? {
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
// Shaped like Spotify's own notification userInfo so SpotifyWatcher.parse accepts it.
// A missing or unreadable number is left out rather than guessed as 0, since a
// made-up position would resync the lyrics to the start of the song.
nonisolated func parseNowPlaying(_ output: String) -> [AnyHashable: Any]? {
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

nonisolated private extension Double {
    var nonNegativeFinite: Double? { isFinite && self >= 0 ? self : nil }
}
