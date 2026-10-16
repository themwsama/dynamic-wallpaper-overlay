import Foundation
func check(_ c: Bool, _ msg: String) { print(c ? "PASS" : "FAIL", msg); if !c { exit(1) } }
check(formatClock(0, showTenths: true) == "00:00.0", "stopwatch zero")
check(formatClock(65.37, showTenths: true) == "01:05.3", "stopwatch tenths")
check(formatClock(3725, showTenths: false) == "1:02:05", "hours format")
let m = ClockModel()
check(m.mode == .stopwatch && !m.isRunning, "starts as idle stopwatch")
m.toggleRunning(); Thread.sleep(forTimeInterval: 0.2); m.toggleRunning()
let paused = m.displayTime
check(paused >= 0.19 && paused < 0.5 && !m.isRunning, "stopwatch counts and pauses")
Thread.sleep(forTimeInterval: 0.1)
check(m.displayTime == paused, "paused time frozen")
m.reset(); check(m.displayTime == 0, "reset clears")
m.setMode(.timer); check(m.displayTime == 1500, "timer default 25 min")
m.adjustDuration(minutes: -30); check(m.timerDuration == 60, "duration clamps at 1 min")
m.adjustDuration(minutes: 200); check(m.timerDuration == 99 * 60, "duration clamps at 99 min")
m.adjustDuration(minutes: -98); var finished = false; m.onFinish = { finished = true }
m.toggleRunning(); check(!m.canAdjustDuration, "can't adjust while running")
m.tick(); check(!finished, "no finish early")
