// Reports which track the Spotify desktop app is on, via its distributed
// playback notification. No polling, no Automation permission needed.
import Foundation
import QuartzCore

let SPOTIFY_NOTIFICATION = Notification.Name("com.spotify.client.PlaybackStateChanged")
let SPOTIFY_TRACK_ID_PREFIX = "spotify:track:"  // excludes episodes and local files
let SPOTIFY_PLAYING_STATE = "Playing"
let SPOTIFY_MS_PER_SECOND: Double = 1000  // "Duration" is milliseconds, "Playback Position" is seconds
let SPOTIFY_KNOWN_STATES: Set<String> = [SPOTIFY_PLAYING_STATE, "Paused", "Stopped"]

struct SpotifyTrack: Equatable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval?
}

final class SpotifyWatcher {
    private(set) var track: SpotifyTrack?
    private(set) var isPlaying = false
    var onTrackChange: ((SpotifyTrack) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onPositionUpdate: ((TimeInterval) -> Void)?
    private(set) var lastPosition: (seconds: TimeInterval, at: CFTimeInterval)?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: SPOTIFY_NOTIFICATION, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo else {
                NSLog("wallpaper-overlay: Spotify notification without userInfo")
                return
            }
            self?.handle(info)
        }
    }

    func stop() {
        guard let observer else { return }
        DistributedNotificationCenter.default().removeObserver(observer)
        self.observer = nil
    }

    // Pure so it can be tested without notifications
    static func parse(_ userInfo: [AnyHashable: Any]) -> (track: SpotifyTrack?, isPlaying: Bool, position: TimeInterval?) {
        let state = userInfo["Player State"] as? String
        if state == nil || !SPOTIFY_KNOWN_STATES.contains(state!) {
            NSLog("wallpaper-overlay: unexpected Spotify Player State: \(String(describing: userInfo["Player State"]))")
        }
        let isPlaying = state == SPOTIFY_PLAYING_STATE
        let position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue.nonNegativeFinite

        let id = (userInfo["Track ID"] as? String) ?? ""
        guard !id.isEmpty else { return (nil, isPlaying, position) }
        guard id.hasPrefix(SPOTIFY_TRACK_ID_PREFIX) else {
            NSLog("wallpaper-overlay: ignoring non-track Spotify ID: \(id)")
            return (nil, isPlaying, position)
        }
        let track = SpotifyTrack(
            id: id,
            name: userInfo["Name"] as? String ?? "",
            artist: userInfo["Artist"] as? String ?? "",
            album: userInfo["Album"] as? String ?? "",
            duration: (userInfo["Duration"] as? NSNumber)?.doubleValue.nonNegativeFinite.map { $0 / SPOTIFY_MS_PER_SECOND }
        )
        return (track, isPlaying, position)
    }

    // Callbacks fire as track change, then position, then state, so a listener
    // that starts work on "playing" already knows the new track and where in it we are.
    // All fields are updated first, so every callback sees the final state.
    func handle(_ userInfo: [AnyHashable: Any]) {
        let parsed = SpotifyWatcher.parse(userInfo)
        let previousID = track?.id
        track = parsed.track
        if let seconds = parsed.position { lastPosition = (seconds, CACurrentMediaTime()) }
        let stateChanged = isPlaying != parsed.isPlaying
        isPlaying = parsed.isPlaying

        if let newTrack = parsed.track, newTrack.id != previousID { onTrackChange?(newTrack) }
        if let seconds = parsed.position { onPositionUpdate?(seconds) }
        if stateChanged { onStateChange?(parsed.isPlaying) }
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
}

private extension Double {
    var nonNegativeFinite: Double? { isFinite && self >= 0 ? self : nil }
}
