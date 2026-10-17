// Listens to Spotify's audio only (its bundle ID), through a
// Core Audio process tap (macOS 26 taps by bundle ID and re-attaches when the
// app relaunches).
// Needs the "System Audio Recording Only" permission, never Screen Recording.
// Nothing is recorded or stored: each buffer is reduced to levels and dropped.
// The private aggregate device is clocked by the output device, so it is torn
// down and rebuilt whenever the default output changes (AirPods, HDMI...).
import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore
import os

// A device switch fires several property changes in a burst; rebuild once after it settles
let TAP_REBUILD_DELAY: TimeInterval = 0.3
// A tap that failed to build is retried when playback resumes, but not more often than this
let TAP_RETRY_MIN_INTERVAL: TimeInterval = 30
let AUDIO_CONTROL_QUEUE_LABEL = "wallpaper-overlay.audio-control"
let TAP_OUTPUT_DEVICE_SELECTORS: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDefaultSystemOutputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
]

private struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (OSStatus \(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw TapError(step: step, status: status) }
}

private func logIfFailed(_ status: OSStatus, _ step: String) {
    guard status != noErr else { return }
    NSLog("wallpaper-overlay: audio tap: %@ failed (OSStatus %d)", step, status)
}

private func systemPropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

// Calls `onChange` on `queue` when the default (or system) output device changes
final class OutputDeviceListener {
    // Stored as the block type so removal passes the very same block object
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue
    private var isInstalled = false

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        block = { _, _ in onChange() }
    }

    deinit { remove() }

    // noErr when every selector was registered
    @discardableResult
    func install() -> OSStatus {
        guard !isInstalled else { return noErr }
        isInstalled = true
        return forEachSelector("add device listener") { address in
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    @discardableResult
    func remove() -> OSStatus {
        guard isInstalled else { return noErr }
        isInstalled = false
        return forEachSelector("remove device listener") { address in
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    private func forEachSelector(_ step: String, _ body: (inout AudioObjectPropertyAddress) -> OSStatus) -> OSStatus {
        var result = noErr
        for selector in TAP_OUTPUT_DEVICE_SELECTORS {
            var address = systemPropertyAddress(selector)
            let status = body(&address)
            logIfFailed(status, step)
            if status != noErr { result = status }
        }
        return result
    }
}

// Threading: every Core Audio create/start/stop/destroy call, the device
// listener and the rebuild debounce run on the private serial `control` queue,
// so a slow teardown never stalls the main thread. Public methods may be called
// from any thread; `suspend`/`resume`/`start` only record the request and hop to
// the queue. What other threads read (levels, health, the requested suspension)
// sits behind unfair locks. The IO block reads nothing but its own analyzer and
// the levels lock: no allocation, no AppKit, nothing main-actor isolated.
//
// Deadlock rule: nothing on `control` ever waits for another thread (no sync to
// main, no semaphores), which is why `stop()` may block on it with `sync`.
// `@unchecked Sendable`: the control-queue state below is never touched elsewhere.
final class SpotifyAudioTap: @unchecked Sendable {
    private struct Status {
        var isHealthy = false
        var isSuspended = false  // what the owner asked for; survives rebuilds
    }

    private let shared = OSAllocatedUnfairLock(initialState: AudioLevels())
    private let status = OSAllocatedUnfairLock(initialState: Status())
    private let ioQueue = DispatchQueue(label: "wallpaper-overlay.app-tap", qos: .userInteractive)
    private let control = DispatchQueue(label: AUDIO_CONTROL_QUEUE_LABEL, qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<Void>()
    private let bundleID = SPOTIFY_BUNDLE_ID
    private let appName = SPOTIFY_DISPLAY_NAME
    private let tapName: String
    private let now: () -> CFTimeInterval
    // Replaces the Core Audio build steps; lets tests drive the queue logic without a real tap
    private let buildOverride: (() throws -> Void)?

    // Control-queue state: only touched from `control`
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isIORunning = false
    private var isStarted = false
    private var lastBuildAttempt: CFTimeInterval?
    private var deviceListener: OutputDeviceListener?
    private var rebuildWork: DispatchWorkItem?

    init(now: @escaping () -> CFTimeInterval = CACurrentMediaTime,
         buildOverride: (() throws -> Void)? = nil) {
        tapName = "Wallpaper Overlay \(appName) glow"
        self.now = now
        self.buildOverride = buildOverride
        control.setSpecific(key: controlKey, value: ())
    }

    // False until the tap is built, and after it couldn't be built or
    // AudioDeviceStart/Stop failed; the glow then falls back to Spotify's play state
    var isHealthy: Bool { status.withLock { $0.isHealthy } }

    // Whether the owner currently wants the stream stopped
    var isSuspended: Bool { status.withLock { $0.isSuspended } }

    // Latest levels, safe to read from the render loop
    var levels: AudioLevels { shared.withLock { $0 } }

    deinit { stop() }

    // Builds asynchronously; watch `isHealthy`. The device listener stays even if
    // the build fails, so a later output change can heal it
    func start() {
        control.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            if self.deviceListener == nil {
                let listener = OutputDeviceListener(queue: self.control) { [weak self] in self?.scheduleRebuild() }
                listener.install()
                self.deviceListener = listener
            }
            self.build()
        }
    }

    // Stops and restarts the audio stream without tearing down the tap, so the
    // overlay isn't processing silence while Spotify is paused or closed
    func suspend() {
        setSuspended(true)
    }

    // Also retries a tap that never got built (permission granted later, Spotify
    // installed later...), at most once per TAP_RETRY_MIN_INTERVAL
    func resume() {
        setSuspended(false)
    }

    // Blocks until the control queue has torn everything down. Safe: the queue
    // never waits on its caller, and a call from the queue itself runs inline
    func stop() {
        if DispatchQueue.getSpecific(key: controlKey) != nil {
            shutDown()
        } else {
            control.sync { shutDown() }
        }
    }

    // Calls `completion` on the control queue once everything queued before it ran
    func drain(_ completion: @escaping @Sendable () -> Void) {
        control.async(execute: completion)
    }

    private func setSuspended(_ suspended: Bool) {
        status.withLock { $0.isSuspended = suspended }
        control.async { [weak self] in self?.applySuspension() }
    }

    private func setHealthy(_ healthy: Bool) {
        status.withLock { $0.isHealthy = healthy }
    }

    // MARK: Control queue only

    // Reconciles the stream with the latest requested state, so a burst of
    // suspend/resume calls settles on the last one
    private func applySuspension() {
        guard isStarted else { return }
        if isSuspended {
            stopIO()
            shared.withLock { $0 = AudioLevels() }
            return
        }
        guard procID != nil else {
            rebuildIfDue()
            return
        }
        do {
            try startIO()
            setHealthy(true)
        } catch {
            // A stale aggregate device is the usual cause; one fresh build is cheap
            NSLog("wallpaper-overlay: %@ audio tap failed to resume: %@; rebuilding", appName, "\(error)")
            setHealthy(false)
            rebuild()
        }
    }

    private func shutDown() {
        isStarted = false
        rebuildWork?.cancel()
        rebuildWork = nil
        deviceListener?.remove()
        deviceListener = nil
        teardown()
        setHealthy(false)
    }

    private func rebuildIfDue() {
        if let last = lastBuildAttempt, now() - last < TAP_RETRY_MIN_INTERVAL { return }
        NSLog("wallpaper-overlay: %@ audio tap isn't running; retrying the build", appName)
        rebuild()
    }

    // MARK: Build and teardown

    @discardableResult
    private func build() -> Bool {
        lastBuildAttempt = now()
        do {
            if let buildOverride {
                try buildOverride()
            } else {
                let tapUID = try createTap()
                try createAggregateDevice(tapUID: tapUID)
                try createIOProc()
            }
            if !isSuspended { try startIO() }
            setHealthy(true)
            return true
        } catch {
            NSLog("wallpaper-overlay: %@ audio tap unavailable: %@", appName, "\(error)")
            teardown()
            setHealthy(false)
            return false
        }
    }

    // Levels are kept: they're overwritten by the new stream within a buffer or two
    private func rebuild() {
        teardown()
        build()
    }

    // Control queue: a device switch fires several changes; rebuild once after they settle
    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.rebuildWork = nil
            NSLog("wallpaper-overlay: output device changed; rebuilding the %@ audio tap", self.appName)
            self.rebuild()
        }
        rebuildWork = work
        control.asyncAfter(deadline: .now() + TAP_REBUILD_DELAY, execute: work)
    }

    private func teardown() {
        stopIO()
        if let procID {
            logIfFailed(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID")
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            logIfFailed(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            logIfFailed(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func startIO() throws {
        guard let procID, !isIORunning else { return }
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        isIORunning = true
    }

    private func stopIO() {
        guard let procID, isIORunning else { return }
        isIORunning = false
        let status = AudioDeviceStop(aggregateID, procID)
        logIfFailed(status, "AudioDeviceStop")
        if status != noErr { setHealthy(false) }
    }

    private func createTap() throws -> String {
        let description = CATapDescription()
        description.name = tapName
        description.bundleIDs = [bundleID]
        description.isProcessRestoreEnabled = true
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
        return description.uuid.uuidString
    }

    // A private aggregate device clocked by the current output device, with the tap as its input
    private func createAggregateDevice(tapUID: String) throws {
        let outputUID = try defaultOutputDeviceUID()
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: tapName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")
    }

    // Each build gets a fresh analyzer, so a rebuilt stream starts clean
    private func createIOProc() throws {
        let format = try tapFormat()
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw TapError(step: "tap format is not float PCM", status: -1)
        }
        let analyzer = AudioAnalyzer(sampleRate: Float(format.mSampleRate))
        let formatChannels = max(1, Int(format.mChannelsPerFrame))
        let shared = self.shared
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
            let playTime = hostMediaTime(of: inputTime.pointee)
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self),
                    count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                let channels = buffer.mNumberChannels > 0 ? Int(buffer.mNumberChannels) : formatChannels
                analyzer.process(samples, channels: channels, at: playTime)
            }
            let levels = analyzer.levels
            shared.withLock { $0 = levels }
        }, "AudioDeviceCreateIOProcIDWithBlock")
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = systemPropertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = systemPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
                  "read default output device")
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "read output device UID")
        guard let uid else { throw TapError(step: "output device has no UID", status: -1) }
        return uid.takeRetainedValue() as String
    }
}

// Host time of the buffer in CACurrentMediaTime's timebase, so the renderer can
// compare. A free function: called on the IO thread, so it must stay unisolated.
private func hostMediaTime(of timeStamp: AudioTimeStamp) -> CFTimeInterval {
    guard timeStamp.mFlags.contains(.hostTimeValid) else { return CACurrentMediaTime() }
    return CFTimeInterval(AudioConvertHostTimeToNanos(timeStamp.mHostTime)) / 1_000_000_000
}
