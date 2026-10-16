// Stopwatch / countdown timer state, shared by the widget on every screen.
import Foundation

enum ClockMode {
    case stopwatch, timer
}

final class ClockModel {
    private(set) var mode: ClockMode = .stopwatch
    private(set) var isRunning = false
    private(set) var isFinished = false
    private(set) var timerDuration = TimeInterval(TIMER_DEFAULT_MINUTES * 60)
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?

    private var elapsed: TimeInterval {
        accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    // Stopwatch counts up; timer counts down from its duration
    var displayTime: TimeInterval {
        mode == .stopwatch ? elapsed : max(0, timerDuration - elapsed)
    }

    var canAdjustDuration: Bool { mode == .timer && !isRunning && accumulated == 0 }

    func toggleRunning() {
        if isRunning {
            accumulated = elapsed
            startedAt = nil
            isRunning = false
        } else {
            if isFinished { reset() }
            startedAt = Date()
            isRunning = true
        }
        onChange?()
    }

    func reset() {
        isRunning = false
        isFinished = false
        startedAt = nil
        accumulated = 0
        onChange?()
    }

    func setMode(_ newMode: ClockMode) {
        guard newMode != mode else { return }
        mode = newMode
        reset()
    }

    func adjustDuration(minutes: Int) {
        guard canAdjustDuration else { return }
        let current = Int(timerDuration / 60)
        timerDuration = TimeInterval(min(max(1, current + minutes), TIMER_MAX_MINUTES) * 60)
        onChange?()
    }

    // Called on every display tick; ends the countdown when it reaches zero
    func tick() {
        guard mode == .timer, isRunning, elapsed >= timerDuration else { return }
        accumulated = timerDuration
        startedAt = nil
        isRunning = false
        isFinished = true
        onChange?()
        onFinish?()
    }
}

func formatClock(_ t: TimeInterval, showTenths: Bool) -> String {
    let total = Int(t)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    let base = hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%02d:%02d", minutes, seconds)
    guard showTenths else { return base }
    return base + String(format: ".%d", Int((t - Double(total)) * 10))
}
