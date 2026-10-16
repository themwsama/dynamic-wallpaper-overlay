// Listens to Spotify's audio only, through a Core Audio process tap
// (macOS 26 taps by bundle ID and re-attaches when Spotify relaunches).
// Needs the "System Audio Recording Only" permission, never Screen Recording.
// Nothing is recorded or stored: each buffer is reduced to levels and dropped.
import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore
import os

let SPOTIFY_BUNDLE_ID = "com.spotify.client"
let TAP_NAME = "Wallpaper Overlay Spotify glow"

private struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (OSStatus \(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw TapError(step: step, status: status) }
}

final class SpotifyAudioTap {
    private let shared = OSAllocatedUnfairLock(initialState: AudioLevels())
    private let ioQueue = DispatchQueue(label: "wallpaper-overlay.spotify-tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isSuspended = false

    // Latest levels, safe to read from the render loop
    var levels: AudioLevels { shared.withLock { $0 } }

    func start() -> Bool {
        do {
            let tapUID = try createTap()
            try createAggregateDevice(tapUID: tapUID)
            try startIO()
            return true
        } catch {
            NSLog("wallpaper-overlay: Spotify audio tap unavailable: %@", "\(error)")
            stop()
            return false
        }
    }

    // Stops and restarts the audio stream without tearing down the tap, so the
    // overlay isn't processing silence while Spotify is paused or closed
    func suspend() {
        guard let procID, !isSuspended else { return }
        AudioDeviceStop(aggregateID, procID)
        isSuspended = true
        shared.withLock { $0 = AudioLevels() }
    }

    func resume() {
        guard let procID, isSuspended else { return }
        AudioDeviceStart(aggregateID, procID)
        isSuspended = false
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func createTap() throws -> String {
        let description = CATapDescription()
        description.name = TAP_NAME
        description.bundleIDs = [SPOTIFY_BUNDLE_ID]
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
            kAudioAggregateDeviceNameKey: TAP_NAME,
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

    private func startIO() throws {
        let format = try tapFormat()
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw TapError(step: "tap format is not float PCM", status: -1)
        }
        let analyzer = AudioAnalyzer(sampleRate: Float(format.mSampleRate))
        let channels = Int(format.mChannelsPerFrame)
        let shared = self.shared
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
            let playTime = Self.mediaTime(of: inputTime.pointee)
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self),
                    count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                analyzer.process(samples, channels: max(1, Int(buffer.mNumberChannels) == 0 ? channels : Int(buffer.mNumberChannels)), at: playTime)
            }
            let levels = analyzer.levels
            shared.withLock { $0 = levels }
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    // Host time of the buffer in CACurrentMediaTime's timebase, so the renderer can compare
    private static func mediaTime(of timeStamp: AudioTimeStamp) -> CFTimeInterval {
        guard timeStamp.mFlags.contains(.hostTimeValid) else { return CACurrentMediaTime() }
        return AudioConvertHostTimeToNanos(timeStamp.mHostTime).secondsFromNanos
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
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

private extension UInt64 {
    var secondsFromNanos: CFTimeInterval { CFTimeInterval(self) / 1_000_000_000 }
}
