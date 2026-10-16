// Tracks where Spotify is in the current track so lyrics can sync. Anchors on
// notification positions and a slow AppleScript poll, and interpolates between.
// The poll needs the Automation permission; without it, only notifications sync.
import AppKit
import QuartzCore

let PLAYBACK_POLL_INTERVAL: TimeInterval = 2.0
let PLAYBACK_SMOOTHING_THRESHOLD: TimeInterval = 0.25  // bigger differences are seeks
let PLAYBACK_MAX_FAILURES = 3

protocol SpotifyPositionSource {
    /// Blocking; nil when unavailable.
    func currentPosition() -> TimeInterval?
}

final class AppleScriptPositionSource: SpotifyPositionSource {
    // NSAppleScript isn't thread-safe: only ever called from PlaybackClock's queue
    private var script: NSAppleScript?

    func currentPosition() -> TimeInterval? {
        let script = self.script ?? NSAppleScript(source: "tell application \"Spotify\" to player position")
        self.script = script
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        let seconds = result.doubleValue
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}

final class PlaybackClock {
    private let source: SpotifyPositionSource
    private let now: () -> CFTimeInterval
    private let isSpotifyRunning: () -> Bool
    private let pollQueue = DispatchQueue(label: "wallpaper-overlay.playback-poll")

    // All state below is main-thread only
    private var isPlaying = false
    private var anchorPosition: TimeInterval?
    private var anchorTime: CFTimeInterval = 0
    private var awaitingSync = false
    private var consecutiveFailures = 0
    private var didLogUnavailable = false
    private var timer: DispatchSourceTimer?
    private(set) var isAvailable = true

    init(
        source: SpotifyPositionSource,
        now: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        isSpotifyRunning: @escaping () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: SPOTIFY_BUNDLE_ID).isEmpty
        }
    ) {
        self.source = source
        self.now = now
        self.isSpotifyRunning = isSpotifyRunning
    }

    deinit { timer?.cancel() }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        let current = position()
        isPlaying = playing
        if let current { anchor(current) }
        updateTimer()
    }

    func resync(position: TimeInterval) {
        anchor(position)
        awaitingSync = false
    }

    func reset() {
        anchor(0)
        awaitingSync = true
    }

    func position() -> TimeInterval? {
        guard let anchorPosition else { return nil }
        guard isPlaying, !awaitingSync else { return anchorPosition }
        return anchorPosition + (now() - anchorTime)
    }

    // Query on the poll queue, apply on main
    func pollOnce() {
        pollQueue.async { [weak self] in
            guard let self, self.isSpotifyRunning() else { return }  // querying would launch Spotify
            let polled = self.source.currentPosition()
            DispatchQueue.main.async { self.apply(polled: polled) }
        }
    }

    private func anchor(_ position: TimeInterval) {
        anchorPosition = position
        anchorTime = now()
    }

    private func apply(polled: TimeInterval?) {
        guard isPlaying else { return }  // paused while the query was in flight
        guard let polled else {
            recordFailure()
            return
        }
        consecutiveFailures = 0
        // The poll is stale by the query latency, so for small differences keep the
        // interpolated position and only refresh the anchor; a big gap means a seek.
        if !awaitingSync, let current = position(), abs(current - polled) <= PLAYBACK_SMOOTHING_THRESHOLD {
            anchor(current)
        } else {
            anchor(polled)
        }
        awaitingSync = false
    }

    private func recordFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= PLAYBACK_MAX_FAILURES, isAvailable else { return }
        isAvailable = false
        timer?.cancel()
        timer = nil
        guard !didLogUnavailable else { return }
        didLogUnavailable = true
        NSLog("wallpaper-overlay: Spotify position unavailable (Automation permission denied?); using notification resyncs only")
    }

    private func updateTimer() {
        timer?.cancel()
        timer = nil
        guard isPlaying, isAvailable else { return }
        let newTimer = DispatchSource.makeTimerSource(queue: pollQueue)
        newTimer.schedule(deadline: .now() + PLAYBACK_POLL_INTERVAL, repeating: PLAYBACK_POLL_INTERVAL)
        newTimer.setEventHandler { [weak self] in self?.pollOnce() }
        newTimer.resume()
        timer = newTimer
    }
}
