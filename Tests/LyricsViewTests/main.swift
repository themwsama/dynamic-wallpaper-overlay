// Assert-style tests for the karaoke sweep timing (pure arithmetic, no rendering).
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

// One row: starts after the entry delay, runs the line's duration minus delay and tail
let one = sweepSchedule(rowLengths: [20], now: 100, entryDelay: 0.56, lineDuration: 5)
check("one row begins after the entry delay", one.count == 1 && near(one[0].begin, 100.56))
check("one row spans duration - delay - tail, subtracted once", near(one[0].duration, 5 - 0.56 - 0.3))
check("sweep ends the tail before the line does", near(one[0].begin + one[0].duration, 100 + 5 - 0.3))

// Reduced motion: no entry delay
let still = sweepSchedule(rowLengths: [10], now: 50, entryDelay: 0, lineDuration: 4)
check("no entry delay starts now", near(still[0].begin, 50) && near(still[0].duration, 3.7))

// Two rows: proportional to length, back to back, summing to the total
let two = sweepSchedule(rowLengths: [30, 10], now: 10, entryDelay: 0.5, lineDuration: 8.8)
let total = 8.8 - 0.5 - 0.3
check("two rows split in proportion", near(two[0].duration, total * 0.75) && near(two[1].duration, total * 0.25))
check("second row starts where the first ends", near(two[1].begin, two[0].begin + two[0].duration))
check("rows add up to the whole sweep", near(two[0].duration + two[1].duration, total))
check("last row ends the tail before the line does", near(two[1].begin + two[1].duration, 10 + 8.8 - 0.3))

// Three rows keep the order and the sum
let three = sweepSchedule(rowLengths: [5, 5, 10], now: 0, entryDelay: 0, lineDuration: 10.3)
check("three rows are contiguous", near(three[1].begin, three[0].begin + three[0].duration)
    && near(three[2].begin, three[1].begin + three[1].duration))
check("equal rows get equal time", near(three[0].duration, three[1].duration) && near(three[2].duration, 2 * three[0].duration))

// Short lines get the minimum rather than a negative or tiny sweep
let short = sweepSchedule(rowLengths: [8], now: 0, entryDelay: 0.56, lineDuration: 0.6)
check("short line gets the minimum sweep", near(short[0].duration, LYRICS_SWEEP_MIN_DURATION))
let shortTwo = sweepSchedule(rowLengths: [1, 1], now: 0, entryDelay: 0, lineDuration: 0.1)
check("minimum is shared between rows", near(shortTwo[0].duration + shortTwo[1].duration, LYRICS_SWEEP_MIN_DURATION))

check("no rows gives no slots", sweepSchedule(rowLengths: [], now: 0, entryDelay: 0, lineDuration: 5).isEmpty)
check("empty rows give no slots", sweepSchedule(rowLengths: [0, 0], now: 0, entryDelay: 0, lineDuration: 5).isEmpty)
// Estimated lyrics: no sweep, whatever the line looks like; synced lyrics unchanged
for (rows, delay, duration) in [([20], 0.56, 5.0), ([30, 10], 0.5, 8.8), ([8], 0, 0.6)] as [([Int], Double, Double)] {
    let estimated = lineSweepSchedule(isEstimated: true, rowLengths: rows, now: 100, entryDelay: delay, lineDuration: duration)
    let synced = lineSweepSchedule(isEstimated: false, rowLengths: rows, now: 100, entryDelay: delay, lineDuration: duration)
    check("estimated \(rows) schedules no sweep", estimated.isEmpty)
    check("synced \(rows) schedule matches sweepSchedule", synced == sweepSchedule(rowLengths: rows, now: 100, entryDelay: delay, lineDuration: duration) && synced.count == rows.count)
}
check("estimated opacity is 0.85 of normal", LYRICS_ESTIMATED_OPACITY == 0.85)
check("estimated marker constant", LYRICS_ESTIMATED_MARKER.contains("approximate") && LYRICS_ESTIMATED_MARKER_ALPHA == 0.5)
check("constants", LYRICS_SWEEP_TAIL == 0.3 && LYRICS_SWEEP_MIN_DURATION == 0.5)

// Placeholder: the track name and artist, dim, no sweep, replaced by the first real line
let view = LyricsView(frame: NSRect(origin: .zero, size: LYRICS_BOX))
func containers() -> [CALayer] { view.layer?.sublayers ?? [] }
func allLayers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(allLayers) }
view.showPlaceholder(title: "Invented Title", artist: "Invented Artist")
check("placeholder adds one container", containers().count == 1)
check("placeholder is dim: 60% of the box opacity", containers().first?.opacity == LYRICS_PLACEHOLDER_OPACITY && LYRICS_PLACEHOLDER_OPACITY == 0.6)
let textLayers = containers().first.map(allLayers)?.compactMap { $0 as? CATextLayer } ?? []
func rowY(_ text: String) -> CGFloat? { textLayers.first { ($0.string as? NSAttributedString)?.string == text }?.frame.minY }
check("placeholder draws the title and the artist", textLayers.count == 2 && rowY("Invented Title") != nil && rowY("Invented Artist") != nil)
check("placeholder puts the title above the artist (y points up)", (rowY("Invented Title") ?? 0) > (rowY("Invented Artist") ?? 1))
check("placeholder has no karaoke sweep", containers().first.map(allLayers)?.contains { $0.mask != nil } == false)
check("placeholder has no per-character entry animation", containers().first.map(allLayers)?.contains { $0.animation(forKey: "entry") != nil } == false)
check("placeholder fades in like a line", containers().first?.animation(forKey: "fadeIn") != nil)
view.showPlaceholder(title: "Invented Title", artist: "Invented Artist")
check("placeholder again retires the previous one", containers().count == 2 && containers().first?.animation(forKey: "exit") != nil)
view.show(text: "Invented first line", romaji: nil, duration: 4, accent: .white, reducedMotion: false)
check("a real line retires the placeholder with the normal exit", containers().count == 3 && containers()[1].animation(forKey: "exit") != nil)
check("the real line has the sweep", containers().last.map(allLayers)?.contains { $0.mask != nil } == true && containers().last?.opacity == 1)
view.removeLine()
check("removeLine frees the placeholder too", containers().isEmpty)
view.showPlaceholder(title: "", artist: "")
check("an empty title and artist draws nothing", containers().isEmpty)
view.showPlaceholder(title: "A title that is far too long to fit in a three hundred sixty point wide box at fourteen points", artist: "Invented Artist")
check("a long title is truncated, not wrapped", containers().first.map(allLayers)?.compactMap { $0 as? CATextLayer }.allSatisfy { $0.truncationMode == .end && !$0.isWrapped } == true)

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
