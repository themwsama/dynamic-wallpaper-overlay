// Tells the overlay when nobody can see the wallpaper: displays asleep,
// screen locked, another user's session in front, or every backdrop window
// fully covered (e.g. a full-screen app). The renderer pauses then, and
// lets go of its video frames.
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
        observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { _ in }
    }

    deinit {
        observers.forEach { center, token in center.removeObserver(token) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (VisibilityMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            update(self)
            self.reevaluate()
        }
        observers.append((center, token))
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
