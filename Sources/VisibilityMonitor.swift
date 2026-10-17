// Tells the overlay when nobody can see the wallpaper: displays asleep,
// screen locked, another user's session in front, or every backdrop window
// fully covered (e.g. a full-screen app). The renderer pauses then, and
// lets go of its video frames. Each backdrop view tracks its own window's
// occlusion (see BackdropView), so a covered screen can stop drawing while the
// others keep going.
import AppKit

final class VisibilityMonitor {
    private let backdrops: () -> [NSWindow]
    private var isAsleep = false
    private var isLocked = false
    private var isSessionInactive = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var isVisible = true
    var onChange: ((Bool) -> Void)?

    init(backdrops: @escaping () -> [NSWindow]) {
        self.backdrops = backdrops
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.isAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.isAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionInactive = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
        observeOcclusion()
    }

    // Isolated: the observer tokens are main-actor state
    isolated deinit {
        observers.forEach { center, token in center.removeObserver(token) }
    }

    // Observers are delivered on `.main`, so their blocks really run on the main actor
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ update: @escaping @MainActor @Sendable (VisibilityMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.reevaluate()
            }
        }
        observers.append((center, token))
    }

    private func observeOcclusion() {
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reevaluate() } }
        observers.append((NotificationCenter.default, token))
    }

    // Also called after the backdrop windows are rebuilt
    func reevaluate() {
        let windows = backdrops()
        let anyBackdropShowing = windows.isEmpty || windows.contains { $0.occlusionState.contains(.visible) }
        let visible = !isAsleep && !isLocked && !isSessionInactive && anyBackdropShowing
        guard visible != isVisible else { return }
        isVisible = visible
        NSLog("wallpaper-overlay: wallpaper %@", visible ? "visible, resuming" : "hidden, pausing and releasing frames")
        onChange?(visible)
    }
}
