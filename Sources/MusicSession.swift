// The Spotify session: owns the SpotifyWatcher and the audio tap on Spotify,
// keeps the tap running only while music plays (with a short grace on pause),
// picks up a song already playing at launch, and forgets everything when
// Spotify quits. Consumers (genre, lyrics, glow) only see the callbacks below.
import AppKit

let AUDIO_TAP_IDLE_GRACE: TimeInterval = 15

// Dev/testing switches, read once from the environment at launch (value "1" turns
// one on). They let a throwaway test build run without asking for permissions:
// WALLPAPER_OVERLAY_NO_AUDIO_TAP=1  never builds the Core Audio tap (no "System
//                                   Audio Recording" prompt; the glow follows play state)
// WALLPAPER_OVERLAY_NO_APPLESCRIPT=1 never scripts Spotify (no Automation prompt; no
//                                   launch-time track query, no position poll)
let AUDIO_TAP_DISABLE_ENV = "WALLPAPER_OVERLAY_NO_AUDIO_TAP"
let APPLESCRIPT_DISABLE_ENV = "WALLPAPER_OVERLAY_NO_APPLESCRIPT"

func isDevSwitchOn(_ name: String, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    env[name] == "1"
}

// Runs `work` after `delay` seconds on the main queue; injected so tests don't sleep
typealias MusicSessionScheduler = (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void

final class MusicSession {
    let watcher: SpotifyWatcher
    private let tap: SpotifyAudioTap
    private let schedule: MusicSessionScheduler
    private let isAppRunning: (String) -> Bool
    private let workspaceCenter: NotificationCenter
    private let isAudioTapEnabled: Bool
    private let isScriptingEnabled: Bool
    private var terminationObserver: NSObjectProtocol?
    private var tapSuspendWork: DispatchWorkItem?

    var onTrack: ((SpotifyTrack) -> Void)?
    var onPlayState: ((Bool) -> Void)?
    var onPosition: ((TimeInterval) -> Void)?
    // The player stopped for good (quit, or stopped with no track): forget the song
    var onEnded: (() -> Void)?

    var isPlaying: Bool { watcher.isPlaying }
    var track: SpotifyTrack? { watcher.track }
    var lastPosition: SpotifyPositionStamp? { watcher.lastPosition }

    // The defaults are the real thing; tests inject a private notification center, a canned
    // script runner, the app-running check, the scheduler and a tap whose build is stubbed.
    // The two `is...Enabled` flags default to the dev/testing environment switches above.
    init(
        notificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        runScript: @escaping SpotifyScriptRunner = runAppleScript,
        makeTap: () -> SpotifyAudioTap = { SpotifyAudioTap() },
        schedule: @escaping MusicSessionScheduler = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
        isAppRunning: @escaping (String) -> Bool = isApplicationRunning,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        isAudioTapEnabled: Bool = !isDevSwitchOn(AUDIO_TAP_DISABLE_ENV),
        isScriptingEnabled: Bool = !isDevSwitchOn(APPLESCRIPT_DISABLE_ENV)
    ) {
        watcher = SpotifyWatcher(center: notificationCenter, runScript: runScript, isAppRunning: isAppRunning)
        tap = makeTap()
        self.schedule = schedule
        self.isAppRunning = isAppRunning
        self.workspaceCenter = workspaceCenter
        self.isAudioTapEnabled = isAudioTapEnabled
        self.isScriptingEnabled = isScriptingEnabled
    }

    // Isolated: stopping the watcher touches main-actor state
    isolated deinit {
        if let terminationObserver { workspaceCenter.removeObserver(terminationObserver) }
        watcher.stop()
    }

    func start() {
        // A tap that was never started ignores suspend/resume, so nothing else changes
        if isAudioTapEnabled {
            tap.start()
        } else {
            NSLog("wallpaper-overlay: audio tap disabled by %@=1 (dev/testing)", AUDIO_TAP_DISABLE_ENV)
        }
        if !isScriptingEnabled {
            NSLog("wallpaper-overlay: Spotify scripting disabled by %@=1 (dev/testing)", APPLESCRIPT_DISABLE_ENV)
        }
        watcher.onTrackChange = { [weak self] track in self?.trackChanged(track) }
        watcher.onStateChange = { [weak self] playing in self?.playStateChanged(playing) }
        watcher.onPositionUpdate = { [weak self] seconds in self?.onPosition?(seconds) }
        terminationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            // Delivered on `.main`, so this really is on the main actor
            MainActor.assumeIsolated { self?.appTerminated(bundleID: bundleID) }
        }
        updateAudioTap(playing: false)
        watcher.start()
        bootstrap()
    }

    // Glow follows Spotify's real audio when the tap is healthy, else its play state
    func audioLevels() -> AudioLevels? {
        guard tap.isHealthy else { return nil }
        return tap.levels
    }

    // With scripting disabled the clock never polls (it treats Spotify as not running)
    // and syncs from notifications only
    func makePlaybackClock() -> PlaybackClock {
        let source = watcher.makePositionSource()
        guard isScriptingEnabled else {
            return PlaybackClock(bundleID: SPOTIFY_BUNDLE_ID, source: source, isAppRunning: { false })
        }
        return PlaybackClock(bundleID: SPOTIFY_BUNDLE_ID, source: source)
    }

    // Spotify quit: nothing should keep interpolating a position for a player that's gone
    func appTerminated(bundleID: String?) {
        guard bundleID == SPOTIFY_BUNDLE_ID else { return }
        watcher.reset()
        onEnded?()
        updateAudioTap(playing: false, immediately: true)
    }

    private func trackChanged(_ track: SpotifyTrack) {
        NSLog("wallpaper-overlay: now playing %@ – %@", track.artist, track.name)
        onTrack?(track)
    }

    private func playStateChanged(_ playing: Bool) {
        onPlayState?(playing)
        if !playing && watcher.track == nil { onEnded?() }
        updateAudioTap(playing: playing)
    }

    // Pick up a song that was already playing before the overlay started
    private func bootstrap() {
        guard isScriptingEnabled else { return }
        watcher.fetchNowPlaying { [weak self] snapshot in
            // Spotify may have quit while the query ran; its answer is stale then
            guard let self, let snapshot, self.watcher.track == nil,
                  self.isAppRunning(SPOTIFY_BUNDLE_ID) else { return }
            self.watcher.apply(snapshot)
        }
    }

    // The audio stream only runs while music plays; a pause keeps it for a
    // short grace period so quick pause/play doesn't restart it
    // The tap keeps this suspended state even while it couldn't be built
    private func updateAudioTap(playing: Bool, immediately: Bool = false) {
        tapSuspendWork?.cancel()
        tapSuspendWork = nil
        if playing {
            tap.resume()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.tap.suspend() }
        tapSuspendWork = work
        schedule(immediately ? 0 : AUDIO_TAP_IDLE_GRACE, work)
    }
}
