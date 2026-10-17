// Loops the stacked wallpaper video (original on the top half, glass on the
// bottom) and hands out its current frame for the Metal renderer. One
// source feeds every screen, so all screens stay on the same frame.
// Frames stay in the decoder's compact 4:2:0 format (the shader converts),
// and a single item loops by seeking, so there's only one small frame pool.
import AVFoundation

final class VideoFrameSource {
    private let player = AVPlayer()
    private let item: AVPlayerItem
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    private var latest: CVPixelBuffer?
    private var loopObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var hasLoggedFailure = false

    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("wallpaper-overlay: backdrop video missing at %@", url.path)
            return nil
        }
        item = AVPlayerItem(url: url)
        item.add(output)
        player.isMuted = true
        // A wallpaper must never keep the display awake
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        player.replaceCurrentItem(with: item)
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // A corrupt or unsupported file only fails after init; without this the
        // wallpaper would stay transparent with nothing in the log
        // @Sendable, so nonisolated: KVO may fire on whichever thread changed the
        // status, and a main-actor closure would trap there under Swift 6
        statusObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.reportFailure(item.error) }
        }
        player.play()
    }

    // Logs once; pixelBuffer keeps returning nil so the renderer draws nothing
    private func reportFailure(_ error: Error?) {
        guard !hasLoggedFailure else { return }
        hasLoggedFailure = true
        latest = nil
        NSLog("wallpaper-overlay: backdrop video failed to load: %@",
              error.map { "\($0.localizedDescription) (\($0))" } ?? "unknown error")
    }

    // Isolated: the observer tokens are main-actor state
    isolated deinit {
        statusObservation?.invalidate()
        loopObserver.map(NotificationCenter.default.removeObserver)
    }

    // Stops decoding and drops the held frame while nobody can see the wallpaper
    func pause() {
        player.pause()
        latest = nil
    }

    func resume() {
        player.play()
    }

    // Newest decoded frame for the given host time, or the last one if nothing new
    func pixelBuffer(atHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
        guard item.status != .failed else { return nil }
        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            latest = buffer
        }
        return latest
    }
}
