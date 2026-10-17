// Tracks where Spotify is in the current track so lyrics can sync. Anchors
// on notification positions and a slow AppleScript poll, and interpolates between.
// The poll needs the Automation permission; without it, only notifications sync,
// and the poll keeps probing slowly so granting the permission later heals it.
// Other failures (no current track, a timeout) are transient and keep the fast poll.
import AppKit
import QuartzCore

let PLAYBACK_POLL_INTERVAL: TimeInterval = 2.0
let PLAYBACK_RETRY_INTERVAL: TimeInterval = 60  // one probe this often while polling keeps failing
let PLAYBACK_SMOOTHING_THRESHOLD: TimeInterval = 0.25  // bigger differences are seeks
let PLAYBACK_MAX_FAILURES = 3
// AppleScript errors that mean polling can't work until something outside changes
let APPLESCRIPT_NOT_AUTHORIZED = -1743
let APPLESCRIPT_APP_NOT_RUNNING = -600

// Blocking position query for PlaybackClock's slow poll. Queried on `queue`, so
// conformers are nonisolated and Sendable (state confined to that queue).
nonisolated protocol SpotifyPositionSource: AnyObject, Sendable {
    /// The serial queue every query must run on (scripting APIs aren't thread-safe).
    var queue: DispatchQueue { get }
    /// Blocking; nil when unavailable.
    func currentPosition() -> TimeInterval?
    /// AppleScript error number of the last failed query, if it had one. Read right
    /// after `currentPosition()` on the same queue.
    var lastErrorNumber: Int? { get }
}

nonisolated extension SpotifyPositionSource {
    var lastErrorNumber: Int? { nil }
}

// Nonisolated: the position poll asks this on the script queue
nonisolated func isApplicationRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

// Runs a one-line "player position" script against Spotify.
// `@unchecked Sendable`: the mutable state is only touched on `queue`.
nonisolated final class AppleScriptPositionSource: SpotifyPositionSource, @unchecked Sendable {
    let queue: DispatchQueue
    private let source: String
    // NSAppleScript isn't thread-safe: only ever called on `queue`
    private var script: NSAppleScript?
    private(set) var lastErrorNumber: Int?

    init(script: String, queue: DispatchQueue) {
        source = script
        self.queue = queue
    }

    func currentPosition() -> TimeInterval? {
        let script = self.script ?? NSAppleScript(source: source)
        self.script = script
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        lastErrorNumber = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        guard let result, error == nil else { return nil }
        let seconds = result.doubleValue
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}

final class PlaybackClock {
    private let appName = "Spotify"
    private let source: SpotifyPositionSource
    private let now: () -> CFTimeInterval
    private let isAppRunning: @Sendable () -> Bool
    private let log: (String) -> Void

    // All state below is main-thread only
    private var isPlaying = false
    private var anchorPosition: TimeInterval?
    private var anchorTime: CFTimeInterval = 0
    private var awaitingSync = false
    private var consecutiveFailures = 0
    private var hasLoggedTransientFailures = false
    // Bumped whenever the position is set from outside (reset, resync), so a
    // poll that was already in flight, and so older than that, is dropped
    private var epoch = 0
    // A hung Spotify can hold a script for a long time; don't queue more behind it
    private var isPollInFlight = false
    private var timer: DispatchSourceTimer?
    private(set) var isAvailable = true

    // Seconds between polls right now: normal while they work, slow while they don't
    var pollInterval: TimeInterval { isAvailable ? PLAYBACK_POLL_INTERVAL : PLAYBACK_RETRY_INTERVAL }

    // `isAppRunning` defaults to asking NSWorkspace about `bundleID`
    init(
        bundleID: String,
        source: SpotifyPositionSource,
        now: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        isAppRunning: (@Sendable () -> Bool)? = nil,
        log: @escaping (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.source = source
        self.now = now
        self.isAppRunning = isAppRunning ?? { isApplicationRunning(bundleID) }
        self.log = log
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
        epoch += 1
        anchor(position)
        awaitingSync = false
    }

    func reset() {
        epoch += 1
        anchor(0)
        awaitingSync = true
    }

    func position() -> TimeInterval? {
        guard let anchorPosition else { return nil }
        guard isPlaying, !awaitingSync else { return anchorPosition }
        return anchorPosition + (now() - anchorTime)
    }

    // Main thread. Queries on the source's script queue, applies back on main.
    // `completion` runs on main once the result was applied or dropped.
    // The queue work is nonisolated: it only touches the Sendable source and
    // running check captured here, never main-actor state, and hands its result
    // to `finish`, which is built here and only ever runs on the main actor.
    func pollOnce(completion: (() -> Void)? = nil) {
        let startEpoch = epoch
        isPollInFlight = true
        let source = self.source
        let isAppRunning = self.isAppRunning
        let finish: @MainActor @Sendable (_ isRunning: Bool, _ polled: TimeInterval?, _ errorNumber: Int?) -> Void = {
            [weak self] isRunning, polled, errorNumber in
            guard let self else { return }
            self.isPollInFlight = false
            if isRunning { self.apply(polled: polled, errorNumber: errorNumber, epoch: startEpoch) }
            completion?()
        }
        source.queue.async { [weak self] in
            guard self != nil else { return }
            // Querying Spotify while it's closed would launch it
            let isRunning = isAppRunning()
            let polled = isRunning ? source.currentPosition() : nil
            let errorNumber = polled == nil ? source.lastErrorNumber : nil
            DispatchQueue.main.async { finish(isRunning, polled, errorNumber) }
        }
    }

    private func anchor(_ position: TimeInterval) {
        anchorPosition = position
        anchorTime = now()
    }

    private func apply(polled: TimeInterval?, errorNumber: Int?, epoch polledEpoch: Int) {
        guard polledEpoch == epoch else { return }  // a seek, reset or notification landed meanwhile
        guard isPlaying else { return }  // paused while the query was in flight
        guard let polled else {
            recordFailure(errorNumber: errorNumber)
            return
        }
        recordSuccess()
        // The poll is stale by the query latency, so for small differences keep the
        // interpolated position and only refresh the anchor; a big gap means a seek.
        if !awaitingSync, let current = position(), abs(current - polled) <= PLAYBACK_SMOOTHING_THRESHOLD {
            anchor(current)
        } else {
            anchor(polled)
        }
        awaitingSync = false
    }

    private func recordSuccess() {
        consecutiveFailures = 0
        hasLoggedTransientFailures = false
        guard !isAvailable else { return }
        isAvailable = true
        log("wallpaper-overlay: \(appName) position polling works again")
        updateTimer()
    }

    // Never gives up. Only errors that need outside action (Automation permission
    // missing, Spotify not running) slow the poll to PLAYBACK_RETRY_INTERVAL, after
    // PLAYBACK_MAX_FAILURES in a row, because the permission can be granted at any
    // time. Anything else (no current track, a timeout) keeps the fast poll.
    private func recordFailure(errorNumber: Int?) {
        consecutiveFailures += 1
        guard consecutiveFailures >= PLAYBACK_MAX_FAILURES, isAvailable else { return }
        guard let errorNumber, let reason = slowRetryReason(errorNumber) else {
            logTransientFailures(errorNumber: errorNumber)
            return
        }
        isAvailable = false
        log("wallpaper-overlay: \(appName) position unavailable (AppleScript error \(errorNumber): \(reason)); "
            + "using notification resyncs and probing every \(Int(PLAYBACK_RETRY_INTERVAL))s")
        updateTimer()
    }

    private func slowRetryReason(_ errorNumber: Int) -> String? {
        switch errorNumber {
        case APPLESCRIPT_NOT_AUTHORIZED: return "Automation permission denied"
        case APPLESCRIPT_APP_NOT_RUNNING: return "\(appName) not running"
        default: return nil
        }
    }

    // Once per failure streak, so a flaky Spotify doesn't fill the log
    private func logTransientFailures(errorNumber: Int?) {
        guard !hasLoggedTransientFailures else { return }
        hasLoggedTransientFailures = true
        let code = errorNumber.map(String.init) ?? "none"
        log("wallpaper-overlay: \(appName) position polls failing (AppleScript error \(code)); still polling every "
            + "\(Int(PLAYBACK_POLL_INTERVAL))s")
    }

    private func updateTimer() {
        timer?.cancel()
        timer = nil
        guard isPlaying else { return }
        // Main queue on purpose: pollOnce reads main-thread state
        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        newTimer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        newTimer.setEventHandler { [weak self] in
            // The timer's queue is .main, so this really is on the main actor
            MainActor.assumeIsolated {
                guard let self, !self.isPollInFlight else { return }
                self.pollOnce()
            }
        }
        newTimer.resume()
        timer = newTimer
    }
}
